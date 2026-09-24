// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title TestUSDC
/// @notice Testnet-only stand-in for USDC (6 decimals) with a rate-limited public faucet, so
///         anyone reviewing the deployment can buy options without hunting for a faucet.
/// @dev Never deploy on a network where value is at stake.
contract TestUSDC is ERC20 {
    uint256 public constant FAUCET_AMOUNT = 10_000e6;
    uint256 public constant FAUCET_COOLDOWN = 1 hours;

    mapping(address => uint256) public lastFaucet;

    error FaucetCooldown(uint256 availableAt);

    constructor() ERC20("Test USD Coin", "tUSDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /// @notice Mint 10,000 tUSDC to the caller, at most once per hour.
    function faucet() external {
        uint256 last = lastFaucet[msg.sender];
        // last == 0 means "never used", which must not be treated as a timestamp
        if (last != 0 && block.timestamp < last + FAUCET_COOLDOWN) {
            revert FaucetCooldown(last + FAUCET_COOLDOWN);
        }
        lastFaucet[msg.sender] = block.timestamp;
        _mint(msg.sender, FAUCET_AMOUNT);
    }
}
