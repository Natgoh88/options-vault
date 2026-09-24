// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice On-chain realized-volatility tracker and Black-Scholes pricer.
/// @dev All prices and rates are 1e18 fixed-point (SD59x18/UD60x18 compatible).
///      Time is expressed in seconds at the interface and converted to years internally.
interface IPricingEngine {
    error NotKeeper();
    error InsufficientHistory();
    error InvalidInput();

    event SnapshotRecorded(uint256 indexed index, uint256 price, uint256 timestamp);

    /// @notice Keeper pushes a spot price into the rolling window; updates accumulators in O(1).
    function recordSnapshot(uint256 spot) external;

    /// @notice Annualised realized volatility (1e18) from the rolling window.
    function realizedVolatility() external view returns (uint256);

    /// @notice Black-Scholes European call price, quoted in the same units as `spot`.
    function callPrice(uint256 spot, uint256 strike, uint256 vol, uint256 timeToExpiry)
        external
        view
        returns (uint256);

    /// @notice Call delta N(d1) in 1e18.
    function callDelta(uint256 spot, uint256 strike, uint256 vol, uint256 timeToExpiry)
        external
        view
        returns (uint256);

    /// @notice Strike whose call delta equals `targetDelta` (1e18, e.g. 0.3e18), solved in d1-space.
    function strikeForDelta(uint256 spot, uint256 vol, uint256 timeToExpiry, uint256 targetDelta)
        external
        view
        returns (uint256 strike);
}
