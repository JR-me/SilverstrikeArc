// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────
//  SILVERSTRIKE CHECK-IN CONTRACT  (Arc Testnet)
//
//  Rules:
//    • One check-in per wallet per calendar day (UTC).
//    • Streak increments if you check in within 48 hours of
//      your last check-in (forgiving — catches timezone edge cases).
//    • Miss 48 hours → streak resets to 1.
//    • Base reward   : BASE_REWARD  (10 GSTRIKE)
//    • Streak bonus  : +1 GSTRIKE per streak day (capped at BONUS_CAP)
//    • Max per check-in: 10 + 50 = 60 GSTRIKE
//
//  Example rewards:
//    Day  1  →  11 GSTRIKE  (10 base + 1 bonus)
//    Day  7  →  17 GSTRIKE
//    Day 30  →  40 GSTRIKE
//    Day 60+ →  60 GSTRIKE  (cap reached)
// ─────────────────────────────────────────────────────────────

import "@openzeppelin/contracts/access/Ownable.sol";
import "./GStrikeToken_arc.sol";

contract SilverStrikeCheckIn is Ownable {

    // ── Constants ────────────────────────────────────────────
    uint256 public constant BASE_REWARD   = 10 * 10**18;  // 10 GSTRIKE
    uint256 public constant BONUS_PER_DAY =  1 * 10**18;  // 1 GSTRIKE per streak day
    uint256 public constant BONUS_CAP     = 50 * 10**18;  // max 50 bonus GSTRIKE
    uint256 public constant DAY           = 86400;         // seconds in a day
    uint256 public constant STREAK_WINDOW = 48 * 3600;    // 48 hours to maintain streak

    // ── State ────────────────────────────────────────────────
    GStrikeToken public immutable token;

    struct UserData {
        uint256 lastCheckIn;   // unix timestamp of last check-in
        uint256 streak;        // current consecutive-day streak
        uint256 totalCheckIns; // lifetime check-in count
        uint256 totalEarned;   // lifetime GSTRIKE earned (in wei)
    }

    mapping(address => UserData) public users;

    // Leaderboard: top streaks
    address[] public allUsers;
    mapping(address => bool) private _registered;

    // ── Events ───────────────────────────────────────────────
    event CheckedIn(
        address indexed user,
        uint256 streak,
        uint256 reward,
        uint256 timestamp
    );
    event StreakReset(address indexed user, uint256 oldStreak);

    // ── Constructor ──────────────────────────────────────────
    constructor(address tokenAddress) Ownable(msg.sender) {
        token = GStrikeToken(tokenAddress);
    }

    // ── Core: checkIn() ─────────────────────────────────────
    /// @notice Call this once per day to record activity and earn GSTRIKE.
    function checkIn() external {
        UserData storage u = users[msg.sender];
        uint256 now_       = block.timestamp;

        // ── Enforce: only once per UTC calendar day ──────────
        require(
            _utcDay(now_) > _utcDay(u.lastCheckIn),
            "Already checked in today (UTC)"
        );

        // ── Streak logic ─────────────────────────────────────
        uint256 oldStreak = u.streak;
        if (u.lastCheckIn == 0) {
            // First ever check-in
            u.streak = 1;
        } else if (now_ - u.lastCheckIn <= STREAK_WINDOW) {
            // Within 48h → keep streak going
            u.streak += 1;
        } else {
            // Missed the window → reset
            if (oldStreak > 1) emit StreakReset(msg.sender, oldStreak);
            u.streak = 1;
        }

        // ── Calculate reward ─────────────────────────────────
        // Base + (streak × bonus), capped
        uint256 bonus  = u.streak * BONUS_PER_DAY;
        if (bonus > BONUS_CAP) bonus = BONUS_CAP;
        uint256 reward = BASE_REWARD + bonus;

        // ── Update state ─────────────────────────────────────
        u.lastCheckIn   = now_;
        u.totalCheckIns += 1;
        u.totalEarned   += reward;

        // ── Register for leaderboard ─────────────────────────
        if (!_registered[msg.sender]) {
            _registered[msg.sender] = true;
            allUsers.push(msg.sender);
        }

        // ── Mint reward tokens ───────────────────────────────
        token.mint(msg.sender, reward);

        emit CheckedIn(msg.sender, u.streak, reward, now_);
    }

    // ── Views ────────────────────────────────────────────────

    /// @notice Returns all key stats for a wallet.
    function getUser(address wallet) external view returns (
        uint256 streak,
        uint256 lastCheckIn,
        uint256 totalCheckIns,
        uint256 totalEarned,
        bool    canCheckInToday,
        uint256 nextReward
    ) {
        UserData memory u = users[wallet];
        uint256 now_      = block.timestamp;

        streak          = u.streak;
        lastCheckIn     = u.lastCheckIn;
        totalCheckIns   = u.totalCheckIns;
        totalEarned     = u.totalEarned;
        canCheckInToday = _utcDay(now_) > _utcDay(u.lastCheckIn);

        // Preview what the next reward would be
        uint256 projectedStreak = streak + 1;
        uint256 bonus = projectedStreak * BONUS_PER_DAY;
        if (bonus > BONUS_CAP) bonus = BONUS_CAP;
        nextReward = BASE_REWARD + bonus;
    }

    /// @notice Returns number of registered users.
    function totalUsers() external view returns (uint256) {
        return allUsers.length;
    }

    /// @notice Returns a paginated slice of users for leaderboard building.
    /// @dev    Sorting by streak is done off-chain (frontend/backend) to
    ///         avoid unbounded gas loops.
    function getUsers(uint256 offset, uint256 limit)
        external
        view
        returns (address[] memory addrs, uint256[] memory streaks)
    {
        uint256 end = offset + limit;
        if (end > allUsers.length) end = allUsers.length;
        uint256 count = end - offset;

        addrs   = new address[](count);
        streaks = new uint256[](count);

        for (uint256 i = 0; i < count; i++) {
            address a  = allUsers[offset + i];
            addrs[i]   = a;
            streaks[i] = users[a].streak;
        }
    }

    // ── Internal helpers ─────────────────────────────────────

    /// @dev Returns the UTC day number for a unix timestamp.
    ///      Two timestamps on the same UTC calendar day return the same value.
    function _utcDay(uint256 ts) internal pure returns (uint256) {
        return ts / DAY;
    }
}
