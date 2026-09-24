// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice ERC-1155 option position. One token id per (strike, expiry) pair.
interface IOptionToken {
    error NotVault();

    function tokenId(uint256 strike, uint256 expiry) external pure returns (uint256);

    /// @dev Vault-only.
    function mint(address to, uint256 strike, uint256 expiry, uint256 amount) external;

    /// @dev Vault-only. Burns holder's tokens on settlement.
    function burn(address from, uint256 strike, uint256 expiry, uint256 amount) external;
}
