// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ═══════════════════════════════════════════════════════════════════════════
//  SilverStrikeOnboarding.sol
//
//  Deployed on Arc Testnet — Chain ID 5042002
//
//  Receives USDC from the owner, distributes a fixed amount to new players
//  via the relayer. Every claim is recorded on-chain as a PlayerOnboarded
//  event — visible in the block explorer as a named contract interaction.
//
//  Deploy:
//    1. Deploy this contract (send some USDC with the constructor)
//    2. Set ONBOARD_CONTRACT_ADDRESS env var in Vercel to the deployed address
//    3. The relayer calls claim(playerAddress) — no longer sends directly
//
//  Refunding:
//    Just send USDC to the contract address — it accepts plain transfers.
// ═══════════════════════════════════════════════════════════════════════════

contract SilverStrikeOnboarding {

    // ── State ──────────────────────────────────────────────────────────────
    address public owner;
    address public relayer;      // the Vercel relayer wallet address
    uint256 public claimAmount;  // USDC per new player (default 0.01)
    uint256 public totalClaims;  // lifetime claim counter

    // ── Events ─────────────────────────────────────────────────────────────
    event PlayerOnboarded(address indexed player, uint256 amount, uint256 claimNumber);
    event ClaimAmountUpdated(uint256 oldAmount, uint256 newAmount);
    event RelayerUpdated(address oldRelayer, address newRelayer);
    event Funded(address indexed from, uint256 amount);
    event Withdrawn(address indexed to, uint256 amount);

    // ── Modifiers ───────────────────────────────────────────────────────────
    modifier onlyOwner()   { require(msg.sender == owner,   "Only owner");   _; }
    modifier onlyRelayer() { require(msg.sender == relayer, "Only relayer"); _; }

    // ── Constructor ─────────────────────────────────────────────────────────
    // Fund at deploy: pass value in the constructor call (e.g. 0.5 USDC)
    constructor(address _relayer) payable {
        require(_relayer != address(0), "Invalid relayer");
        owner       = msg.sender;
        relayer     = _relayer;
        claimAmount = 10_000; // 0.01 USDC (6 decimals: 10_000 = 0.01 × 10^6)
    }

    // ── Core: called by the Vercel relayer ──────────────────────────────────
    // Shows on explorer as: SilverStrikeOnboarding · claim()
    function claim(address payable player) external onlyRelayer {
        require(player != address(0),             "Invalid player address");
        require(player != owner,                  "Owner cannot claim");
        require(player != relayer,                "Relayer cannot claim");
        require(address(this).balance >= claimAmount, "Insufficient contract balance");

        totalClaims++;
        player.transfer(claimAmount);

        emit PlayerOnboarded(player, claimAmount, totalClaims);
    }

    // ── View helpers ────────────────────────────────────────────────────────
    function contractBalance() external view returns (uint256) {
        return address(this).balance;
    }

    function claimsRemaining() external view returns (uint256) {
        if (claimAmount == 0) return 0;
        return address(this).balance / claimAmount;
    }

    // ── Owner controls ──────────────────────────────────────────────────────
    function setClaimAmount(uint256 newAmount) external onlyOwner {
        require(newAmount > 0, "Amount must be > 0");
        emit ClaimAmountUpdated(claimAmount, newAmount);
        claimAmount = newAmount;
    }

    function setRelayer(address newRelayer) external onlyOwner {
        require(newRelayer != address(0), "Invalid address");
        emit RelayerUpdated(relayer, newRelayer);
        relayer = newRelayer;
    }

    function withdraw(uint256 amount) external onlyOwner {
        require(amount <= address(this).balance, "Insufficient balance");
        payable(owner).transfer(amount);
        emit Withdrawn(owner, amount);
    }

    function withdrawAll() external onlyOwner {
        uint256 bal = address(this).balance;
        payable(owner).transfer(bal);
        emit Withdrawn(owner, bal);
    }

    // ── Accept plain USDC transfers (refunding the contract) ───────────────
    receive() external payable {
        emit Funded(msg.sender, msg.value);
    }
}
