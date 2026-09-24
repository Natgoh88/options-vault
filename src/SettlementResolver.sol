// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";
import {ISettlementResolver} from "./interfaces/ISettlementResolver.sol";
import {IOptionsVault} from "./interfaces/IOptionsVault.sol";

/// @title SettlementResolver
/// @notice Chainlink ETH/USD adapter.
/// @dev Two trust surfaces, both minimised:
///      1. `spot()`     - checked live price used to pick the strike at epoch start.
///      2. Settlement   - the price in effect at expiry, i.e. the LAST round with
///         updatedAt <= expiry. It is chosen by rule, not by the caller, and is not a spot read in
///         the trigger transaction, so nothing in the settlement transaction can move it.
contract SettlementResolver is ISettlementResolver {
    AggregatorV3Interface public immutable feed;
    /// @notice Optional L2 sequencer uptime feed (address(0) disables the check, e.g. testnets).
    AggregatorV3Interface public immutable sequencerFeed;
    uint256 public immutable heartbeat;
    uint256 public immutable buffer;
    uint256 public immutable sequencerGracePeriod;
    uint8 internal immutable _feedDecimals;

    address public immutable deployer;
    IOptionsVault public vault;

    mapping(uint256 => uint256) internal _settlementPrice;
    mapping(uint256 => uint80) public settlementRound;

    constructor(
        AggregatorV3Interface feed_,
        AggregatorV3Interface sequencerFeed_,
        uint256 heartbeat_,
        uint256 buffer_,
        uint256 sequencerGracePeriod_
    ) {
        uint8 d = feed_.decimals();
        if (d > 18) revert InvalidPrice();
        feed = feed_;
        sequencerFeed = sequencerFeed_;
        heartbeat = heartbeat_;
        buffer = buffer_;
        sequencerGracePeriod = sequencerGracePeriod_;
        _feedDecimals = d;
        deployer = msg.sender;
    }

    /// @notice One-time wiring (vault and resolver reference each other).
    function setVault(IOptionsVault vault_) external {
        if (msg.sender != deployer) revert NotDeployer();
        if (address(vault) != address(0)) revert VaultAlreadySet();
        vault = vault_;
    }

    // ------------------------------------------------------------------
    // Live spot
    // ------------------------------------------------------------------

    /// @inheritdoc ISettlementResolver
    function spot() public view returns (uint256) {
        _checkSequencer();
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) =
            feed.latestRoundData();
        if (answer <= 0 || updatedAt == 0 || answeredInRound < roundId) revert InvalidPrice();
        if (updatedAt > block.timestamp) revert InvalidPrice();
        uint256 maxAge = heartbeat + buffer;
        if (block.timestamp - updatedAt > maxAge) revert StalePrice(updatedAt, maxAge);
        return _scale(answer);
    }

    function _checkSequencer() internal view {
        if (address(sequencerFeed) == address(0)) return;
        (, int256 answer, uint256 startedAt,,) = sequencerFeed.latestRoundData();
        // answer: 0 = up, 1 = down
        if (answer != 0) revert SequencerDown();
        if (block.timestamp - startedAt <= sequencerGracePeriod) revert GracePeriodNotOver();
    }

    // ------------------------------------------------------------------
    // Settlement price (price in effect at expiry)
    // ------------------------------------------------------------------

    /// @inheritdoc ISettlementResolver
    function submitExpiryRound(uint256 epoch, uint80 roundId) external returns (uint256 price) {
        if (address(vault) == address(0)) revert VaultNotSet();
        if (_settlementPrice[epoch] != 0) revert AlreadyRecorded();

        uint256 expiry = vault.epochData(epoch).expiry;
        if (expiry == 0) revert InvalidRound();
        if (block.timestamp <= expiry) revert TooEarly();

        (int256 answer, uint256 updatedAt) = _round(roundId);
        if (updatedAt == 0) revert InvalidRound();
        if (updatedAt > expiry) revert RoundAfterExpiry();
        if (answer <= 0) revert InvalidPrice();
        // the feed must have been fresh at expiry, otherwise refuse rather than settle on stale data
        uint256 maxAge = heartbeat + buffer;
        if (expiry - updatedAt > maxAge) revert StalePrice(updatedAt, maxAge);

        // roundId must be the LAST round at or before expiry
        (, uint256 nextUpdatedAt) = _round(roundId + 1);
        if (nextUpdatedAt != 0) {
            if (nextUpdatedAt <= expiry) revert NotLastRoundBeforeExpiry();
        } else {
            // no successor: only valid if this really is the newest round (not a phase gap)
            (uint80 latestId,,,,) = feed.latestRoundData();
            if (latestId != roundId) revert NotLastRoundBeforeExpiry();
        }

        price = _scale(answer);
        if (price == 0) revert InvalidPrice();
        _settlementPrice[epoch] = price;
        settlementRound[epoch] = roundId;
        emit SettlementPriceSet(epoch, price, roundId);
    }

    /// @inheritdoc ISettlementResolver
    function snapshotSettlementPrice(uint256 epoch) public view returns (uint256 price) {
        price = _settlementPrice[epoch];
        if (price == 0) revert PriceNotRecorded();
    }

    /// @inheritdoc ISettlementResolver
    function payoutPerOption(uint256 epoch, uint256 strike) external view returns (uint256) {
        uint256 price = snapshotSettlementPrice(epoch);
        return price > strike ? (price - strike) * 1e18 / price : 0;
    }

    // ------------------------------------------------------------------

    function _round(uint80 roundId) internal view returns (int256 answer, uint256 updatedAt) {
        try feed.getRoundData(roundId) returns (uint80, int256 a, uint256, uint256 u, uint80) {
            return (a, u);
        } catch {
            return (0, 0); // "No data present"
        }
    }

    function _scale(int256 answer) internal view returns (uint256) {
        return uint256(answer) * 10 ** (18 - _feedDecimals);
    }
}
