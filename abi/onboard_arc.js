// ═══════════════════════════════════════════════════════════════════════
//  SilverStrike — Onboarding Relayer
//  POST /api/onboard
//
//  Calls SilverStrikeOnboarding.claim(playerAddress) on-chain.
//  Shows on block explorer as a named contract interaction.
//
//  Required env vars:
//    RELAYER_PRIVATE_KEY          relayer wallet private key (0x...)
//    ONBOARD_CONTRACT_ADDRESS     deployed SilverStrikeOnboarding address
//    RPC_URL                      https://rpc.testnet.arc.network
//    UPSTASH_REDIS_REST_URL       from upstash.com
//    UPSTASH_REDIS_REST_TOKEN     from upstash.com
//    CLAIM_AMOUNT_ETH             display only — actual amount set in contract
// ═══════════════════════════════════════════════════════════════════════

import { ethers } from 'ethers';

// Minimal ABI — only what we need
const ONBOARD_ABI = [
  'function claim(address payable player) external',
  'function claimAmount() view returns (uint256)',
  'function claimsRemaining() view returns (uint256)',
  'function contractBalance() view returns (uint256)',
];

// ── RPC with fallback URLs + timeout ────────────────────────────────────
let _id = 1;
async function rpc(method, params = []) {
  const urls = [
    process.env.RPC_URL,
    'https://rpc.arc.network',
    'https://rpc2.arc.network',
  ].filter(Boolean);

  let lastErr;
  for (const url of urls) {
    try {
      const res = await fetch(url, {
        method:  'POST',
        headers: { 'Content-Type': 'application/json', 'Accept': 'application/json' },
        body:    JSON.stringify({ jsonrpc: '2.0', id: _id++, method, params }),
        signal:  AbortSignal.timeout(10000),
      });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const json = await res.json();
      if (json.error) throw new Error(`${json.error.code}: ${json.error.message}`);
      return json.result;
    } catch (e) {
      lastErr = e;
      console.warn(`RPC failed on ${url}: ${e.message}`);
    }
  }
  throw new Error(`All RPC endpoints failed. Last: ${lastErr?.message}`);
}

// ── Upstash Redis ────────────────────────────────────────────────────────
const upstashGet = async (key) => {
  const r = await fetch(
    `${process.env.UPSTASH_REDIS_REST_URL}/get/${encodeURIComponent(key)}`,
    { headers: { Authorization: `Bearer ${process.env.UPSTASH_REDIS_REST_TOKEN}` } }
  );
  return (await r.json()).result ?? null;
};

const upstashSet = async (key, value) => {
  await fetch(
    `${process.env.UPSTASH_REDIS_REST_URL}/set/${encodeURIComponent(key)}/${encodeURIComponent(value)}`,
    { headers: { Authorization: `Bearer ${process.env.UPSTASH_REDIS_REST_TOKEN}` } }
  );
};

// ── ABI encode claim(address) call ──────────────────────────────────────
// keccak256("claim(address)") = 0x1e83409a — first 4 bytes
function encodeClaimCall(playerAddress) {
  const iface = new ethers.Interface(ONBOARD_ABI);
  return iface.encodeFunctionData('claim', [playerAddress]);
}

// ── Handler ──────────────────────────────────────────────────────────────
export default async function handler(req, res) {
  res.setHeader('Access-Control-Allow-Origin',  '*');
  res.setHeader('Access-Control-Allow-Methods', 'POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');
  if (req.method === 'OPTIONS') return res.status(200).end();
  if (req.method !== 'POST')   return res.status(405).json({ error: 'Method not allowed' });

  // ── Validate wallet ─────────────────────────────────────────────────
  const { wallet } = req.body ?? {};
  if (!wallet)                   return res.status(400).json({ error: 'Missing wallet address' });
  if (!ethers.isAddress(wallet)) return res.status(400).json({ error: 'Invalid wallet address' });
  const address = ethers.getAddress(wallet);

  // ── Check env vars ──────────────────────────────────────────────────
  const {
    RELAYER_PRIVATE_KEY,
    ONBOARD_CONTRACT_ADDRESS,
    UPSTASH_REDIS_REST_URL,
    UPSTASH_REDIS_REST_TOKEN,
    CLAIM_AMOUNT_ETH = '0.01',
  } = process.env;

  if (!RELAYER_PRIVATE_KEY || !ONBOARD_CONTRACT_ADDRESS || !UPSTASH_REDIS_REST_URL || !UPSTASH_REDIS_REST_TOKEN) {
    console.error('Missing env vars:', {
      RELAYER_PRIVATE_KEY:      !!RELAYER_PRIVATE_KEY,
      ONBOARD_CONTRACT_ADDRESS: !!ONBOARD_CONTRACT_ADDRESS,
      UPSTASH_REDIS_REST_URL:   !!UPSTASH_REDIS_REST_URL,
      UPSTASH_REDIS_REST_TOKEN: !!UPSTASH_REDIS_REST_TOKEN,
    });
    return res.status(500).json({ error: 'Server misconfigured — contact the team.' });
  }

  const contractAddress = ethers.getAddress(ONBOARD_CONTRACT_ADDRESS);

  // ── One-per-wallet check (Redis) ────────────────────────────────────
  const redisKey = `silverstrike:onboard:${address}`;
  const claimed  = await upstashGet(redisKey);
  if (claimed) {
    let claimedAt = '';
    try { claimedAt = JSON.parse(claimed).claimedAt ?? ''; } catch {}
    return res.status(409).json({
      error:   'Already claimed',
      claimed: true,
      message: `Wallet already received onboarding zkLTC.${claimedAt ? ` Claimed ${claimedAt}.` : ''}`,
    });
  }

  // ── Build relayer wallet ─────────────────────────────────────────────
  const key           = RELAYER_PRIVATE_KEY.startsWith('0x') ? RELAYER_PRIVATE_KEY : `0x${RELAYER_PRIVATE_KEY}`;
  const relayerWallet = new ethers.Wallet(key);
  const relayerAddr   = relayerWallet.address;

  try {
    // Encode the claim(address) call
    const calldata = encodeClaimCall(address);

    // Fetch nonce, gas price, gas estimate, chainId in parallel
    const [nonceHex, gasPriceHex, gasEstHex, chainIdHex] = await Promise.all([
      rpc('eth_getTransactionCount', [relayerAddr, 'latest']),
      rpc('eth_gasPrice',            []),
      rpc('eth_estimateGas',         [{ from: relayerAddr, to: contractAddress, data: calldata }]),
      rpc('eth_chainId',             []),
    ]);

    const nonce    = Number(nonceHex);
    const gasPrice = BigInt(gasPriceHex);
    const gasLimit = BigInt(gasEstHex) + 10000n; // buffer for contract execution
    const chainId  = Number(chainIdHex);

    // Sign the contract call transaction
    const signedTx = await relayerWallet.signTransaction({
      to:       contractAddress,
      value:    0n,            // no ETH sent — contract holds the funds
      data:     calldata,
      nonce,
      gasLimit,
      gasPrice,
      chainId,
      type:     0,
    });

    // Broadcast
    const txHash = await rpc('eth_sendRawTransaction', [signedTx]);
    console.log(`✅ PlayerOnboarded: ${txHash} → ${address}`);

    // Mark claimed in Redis
    await upstashSet(redisKey, JSON.stringify({
      txHash,
      claimedAt: new Date().toISOString(),
      amount:    CLAIM_AMOUNT_ETH,
      contract:  contractAddress,
    }));

    return res.status(200).json({
      success:  true,
      txHash,
      amount:   CLAIM_AMOUNT_ETH,
      explorer: `https://explorer.arc.network/tx/${txHash}`,
      message:  `${CLAIM_AMOUNT_ETH} zkLTC sent to your wallet!`,
    });

  } catch (err) {
    const msg = err?.message ?? '';
    console.error('Onboard error:', msg);
    if (msg.includes('insufficient') || msg.includes('balance'))
      return res.status(503).json({ error: 'Contract out of funds. Try the official faucet.', faucet: 'https://faucet.arc.network' });
    if (msg.includes('nonce'))
      return res.status(503).json({ error: 'Relayer busy — retry in a few seconds.' });
    return res.status(500).json({ error: `Transaction failed: ${msg}` });
  }
}
