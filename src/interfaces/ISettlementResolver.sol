// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Reads the Chainlink ETH/USD feed: checked live spot, and a deterministic settlement
///         price per epoch taken from the round in effect at expiry.
interface ISettlementResolver {
    error StalePrice(uint256 updatedAt, uint256 maxAge);
    error InvalidPrice();
    error TooEarly();
    error SequencerDown();
    error GracePeriodNotOver();
    error AlreadyRecorded();
    error PriceNotRecorded();
    error RoundAfterExpiry();
    error NotLastRoundBeforeExpiry();
    error InvalidRound();
    error NotDeployer();
    error VaultAlreadySet();
    error VaultNotSet();

    event SettlementPriceSet(uint256 indexed epoch, uint256 price, uint80 roundId);

    /// @notice Latest checked spot price (1e18). Reverts if stale, non-positive, or the L2
    ///         sequencer is down / just restarted.
    function spot() external view returns (uint256);

    /// @notice Record the settlement price for `epoch` from Chainlink round `roundId`.
    /// @dev Permissionless. `roundId` must be the last round with updatedAt <= expiry, so there is
    ///      exactly one valid answer and the caller has no discretion over the price.
    function submitExpiryRound(uint256 epoch, uint80 roundId) external returns (uint256 price);

    /// @notice The recorded settlement price for `epoch` (1e18). Reverts if not yet recorded.
    function snapshotSettlementPrice(uint256 epoch) external view returns (uint256 price);

    /// @notice Per-option payout in WETH (1e18) for a given strike, from the recorded price.
    function payoutPerOption(uint256 epoch, uint256 strike) external view returns (uint256);
}
