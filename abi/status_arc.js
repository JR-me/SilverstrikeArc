// GET /api/status — checks onboarding contract balance + claims remaining

import { ethers } from 'ethers';

const ONBOARD_ABI = [
  'function claimAmount() view returns (uint256)',
  'function claimsRemaining() view returns (uint256)',
  'function contractBalance() view returns (uint256)',
  'function totalClaims() view returns (uint256)',
];

let _id = 1;
async function rpc(method, params = []) {
  const urls = [
    process.env.RPC_URL,
    'https://rpc.testnet.arc.network',
  ].filter(Boolean);

  let lastErr;
  for (const url of urls) {
    try {
      const res = await fetch(url, {
        method:  'POST',
        headers: { 'Content-Type': 'application/json', 'Accept': 'application/json' },
        body:    JSON.stringify({ jsonrpc: '2.0', id: _id++, method, params }),
        signal:  AbortSignal.timeout(8000),
      });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const json = await res.json();
      if (json.error) throw new Error(json.error.message);
      return json.result;
    } catch (e) { lastErr = e; }
  }
  throw lastErr;
}

export default async function handler(req, res) {
  res.setHeader('Access-Control-Allow-Origin', '*');
  if (req.method !== 'GET') return res.status(405).json({ error: 'Method not allowed' });

  const { ONBOARD_CONTRACT_ADDRESS, CLAIM_AMOUNT_ETH = '0.01' } = process.env;
  if (!ONBOARD_CONTRACT_ADDRESS)
    return res.status(500).json({ available: false, reason: 'Contract address not configured' });

  const contract = ethers.getAddress(ONBOARD_CONTRACT_ADDRESS);

  try {
    const iface = new ethers.Interface(ONBOARD_ABI);

    const [remainingHex, totalHex, balanceHex, claimAmtHex] = await Promise.all([
      rpc('eth_call', [{ to: contract, data: iface.encodeFunctionData('claimsRemaining') }, 'latest']),
      rpc('eth_call', [{ to: contract, data: iface.encodeFunctionData('totalClaims')     }, 'latest']),
      rpc('eth_call', [{ to: contract, data: iface.encodeFunctionData('contractBalance') }, 'latest']),
      rpc('eth_call', [{ to: contract, data: iface.encodeFunctionData('claimAmount')     }, 'latest']),
    ]);

    const claimsLeft   = Number(iface.decodeFunctionResult('claimsRemaining', remainingHex)[0]);
    const totalClaims  = Number(iface.decodeFunctionResult('totalClaims',     totalHex)[0]);
    const balanceZkLTC = parseFloat(ethers.formatEther(iface.decodeFunctionResult('contractBalance', balanceHex)[0]));
    const claimAmount  = ethers.formatEther(iface.decodeFunctionResult('claimAmount', claimAmtHex)[0]);

    return res.status(200).json({
      available:    claimsLeft > 0,
      claimsLeft,
      totalClaims,
      balanceZkLTC: balanceZkLTC.toFixed(4),
      claimAmount,
      contract:     ONBOARD_CONTRACT_ADDRESS,
    });
  } catch (e) {
    return res.status(500).json({ available: false, reason: `RPC error: ${e.message}` });
  }
}
