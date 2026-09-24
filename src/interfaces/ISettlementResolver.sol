// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Reads the Chainlink ETH/USD feed and determines epoch settlement price and payouts.
interface ISettlementResolver {
    error StalePrice(uint256 updatedAt, uint256 maxAge);
    error InvalidPrice();
    error TooEarly();

    event SettlementPriceSet(uint256 indexed epoch, uint256 price);

    /// @notice Latest checked spot price (1e18), reverts if stale or non-positive.
    function spot() external view returns (uint256);

    /// @notice Lock in the settlement price for `epoch`. Must be called at/after expiry.
    function snapshotSettlementPrice(uint256 epoch) external returns (uint256 price);

    /// @notice Per-option payout in collateral asset (WETH, 1e18) for a given strike.
    function payoutPerOption(uint256 epoch, uint256 strike) external view returns (uint256);
}
