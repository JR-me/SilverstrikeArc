// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────
//  SILVER PASS  (ERC-721 NFT Membership)
//
//  Rules:
//    • Costs 100 GSTRIKE to mint (burned on mint)
//    • Unlimited supply
//    • One pass per wallet (optional — enforced below)
//    • Holding the pass = access to SilverStrike Pass Holders
// ─────────────────────────────────────────────────────────────

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IBurnable is IERC20 {
    function burnFrom(address account, uint256 amount) external;
}

contract SilverPass is ERC721, Ownable {

    // ── Config ───────────────────────────────────────────────
    uint256 public constant MINT_COST = 100 * 10**18;  // 100 GSTRIKE

    IBurnable public immutable gStrikeToken;
    uint256 public nextTokenId = 1;

    // ── Events ───────────────────────────────────────────────
    event PassMinted(address indexed to, uint256 tokenId);

    // ── Constructor ──────────────────────────────────────────
    constructor(address _gStrikeToken)
        ERC721("Silver Pass", "SPASS")
        Ownable(msg.sender)
    {
        gStrikeToken = IBurnable(_gStrikeToken);
    }

    // ── Mint ─────────────────────────────────────────────────
    /// @notice Mint a Silver Pass by burning 100 GSTRIKE.
    /// @dev    Caller must first call approve() on GStrikeToken
    ///         to allow this contract to spend 100 GSTRIKE.
    function mint() external {
        // One pass per wallet
        require(balanceOf(msg.sender) == 0, "Already holds a Silver Pass");
        // Pull and burn 100 GSTRIKE from caller
        gStrikeToken.burnFrom(msg.sender, MINT_COST);

        uint256 tokenId = nextTokenId++;
        _safeMint(msg.sender, tokenId);

        emit PassMinted(msg.sender, tokenId);
    }

    /// @notice Check if a wallet holds at least one pass.
    function hasPass(address wallet) external view returns (bool) {
        return balanceOf(wallet) > 0;
    }

    /// @notice Total passes minted so far.
    function totalMinted() external view returns (uint256) {
        return nextTokenId - 1;
    }

    // ── Token URI (simple on-chain SVG) ──────────────────────
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        require(tokenId < nextTokenId, "Token does not exist");
        string memory svg = string(abi.encodePacked(
            '<svg xmlns="http://www.w3.org/2000/svg" width="400" height="400">',
            '<defs><linearGradient id="g" x1="0%" y1="0%" x2="100%" y2="100%">',
            '<stop offset="0%" style="stop-color:#ff6eb4"/><stop offset="100%" style="stop-color:#b48aff"/></linearGradient></defs>',
            '<rect width="400" height="400" rx="32" fill="url(#g)"/>',
            '<text x="200" y="160" font-family="Arial" font-size="80" text-anchor="middle" fill="white">&#10003;</text>',
            '<text x="200" y="230" font-family="Arial" font-size="32" font-weight="bold" text-anchor="middle" fill="white">SILVER PASS</text>',
            '<text x="200" y="275" font-family="Arial" font-size="18" text-anchor="middle" fill="rgba(255,255,255,0.8)">#', 
            _toString(tokenId),
            '</text></svg>'
        ));
        string memory json = string(abi.encodePacked(
            '{"name":"Silver Pass #', _toString(tokenId),
            '","description":"Official SilverStrike community membership pass.",',
            '"image":"data:image/svg+xml;base64,', _base64(bytes(svg)), '"}'
        ));
        return string(abi.encodePacked("data:application/json;base64,", _base64(bytes(json))));
    }

    // ── Internal utils ────────────────────────────────────────
    function _toString(uint256 v) internal pure returns (string memory) {
        if (v == 0) return "0";
        uint256 tmp = v; uint256 digits;
        while (tmp != 0) { digits++; tmp /= 10; }
        bytes memory buf = new bytes(digits);
        while (v != 0) { digits--; buf[digits] = bytes1(uint8(48 + v % 10)); v /= 10; }
        return string(buf);
    }

    bytes internal constant TABLE = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    function _base64(bytes memory data) internal pure returns (string memory) {
        uint256 len = data.length;
        if (len == 0) return "";
        uint256 encodedLen = 4 * ((len + 2) / 3);
        bytes memory result = new bytes(encodedLen + 32);
        bytes memory table = TABLE;
        assembly {
            let tablePtr := add(table, 1)
            let resultPtr := add(result, 32)
            for { let i := 0 } lt(i, len) {} {
                i := add(i, 3)
                let input := and(mload(add(data, i)), 0xffffff)
                let out := mload(add(tablePtr, and(shr(18, input), 0x3F)))
                out := shl(8, out)
                out := add(out, and(mload(add(tablePtr, and(shr(12, input), 0x3F))), 0xFF))
                out := shl(8, out)
                out := add(out, and(mload(add(tablePtr, and(shr(6, input), 0x3F))), 0xFF))
                out := shl(8, out)
                out := add(out, and(mload(add(tablePtr, and(input, 0x3F))), 0xFF))
                out := shl(224, out)
                mstore(resultPtr, out)
                resultPtr := add(resultPtr, 4)
            }
            switch mod(len, 3)
            case 1 { mstore(sub(resultPtr, 2), shl(240, 0x3d3d)) }
            case 2 { mstore(sub(resultPtr, 1), shl(248, 0x3d)) }
            mstore(result, encodedLen)
        }
        return string(result);
    }
}
