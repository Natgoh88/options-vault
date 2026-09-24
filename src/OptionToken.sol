// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {IOptionToken} from "./interfaces/IOptionToken.sol";

/// @title OptionToken
/// @notice ERC-1155 call-option positions, one id per (strike, expiry). Only the vault mints/burns.
contract OptionToken is ERC1155, IOptionToken {
    address public immutable deployer;
    address public vault;

    error VaultAlreadySet();
    error NotDeployer();
    error ZeroAddress();

    event VaultSet(address indexed vault);

    constructor() ERC1155("") {
        deployer = msg.sender;
    }

    /// @notice One-time wiring, needed because vault and token reference each other.
    function setVault(address vault_) external {
        if (msg.sender != deployer) revert NotDeployer();
        if (vault != address(0)) revert VaultAlreadySet();
        if (vault_ == address(0)) revert ZeroAddress();
        vault = vault_;
        emit VaultSet(vault_);
    }

    function tokenId(uint256 strike, uint256 expiry) public pure returns (uint256) {
        return uint256(keccak256(abi.encode(strike, expiry)));
    }

    function mint(address to, uint256 strike, uint256 expiry, uint256 amount) external {
        if (msg.sender != vault) revert NotVault();
        _mint(to, tokenId(strike, expiry), amount, "");
    }

    function burn(address from, uint256 strike, uint256 expiry, uint256 amount) external {
        if (msg.sender != vault) revert NotVault();
        _burn(from, tokenId(strike, expiry), amount);
    }
}
