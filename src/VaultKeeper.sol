// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";
import {IOptionsVault} from "./interfaces/IOptionsVault.sol";
import {PricingEngine} from "./PricingEngine.sol";
import {SettlementResolver} from "./SettlementResolver.sol";

/// @notice Chainlink Automation compatible interface.
interface AutomationCompatibleInterface {
    function checkUpkeep(bytes calldata checkData)
        external
        returns (bool upkeepNeeded, bytes memory performData);
    function performUpkeep(bytes calldata performData) external;
}

/// @title VaultKeeper
/// @notice Single keeper for the whole system. It is the `keeper` on PricingEngine and
///         OptionsVault, and is driven by one Chainlink Automation upkeep that does two jobs:
///         hourly price snapshots for the volatility window, and the epoch lifecycle.
/// @dev `checkUpkeep` runs off-chain (simulated) and `performUpkeep` lands in a later block, so what
///      is due can change in between (e.g. the writing window closes). `performUpkeep` therefore
///      ignores `performData` and executes whatever is due at execution time: stale simulations still
///      succeed, and forged data cannot select an action.
///      If a lifecycle action unexpectedly reverts, a due snapshot is still recorded so the
///      volatility window never starves; if no snapshot is due the whole call reverts, which keeps
///      Automation from burning gas on a no-op every block.
contract VaultKeeper is AutomationCompatibleInterface {
    enum Action {
        None,
        Snapshot,
        StartEpoch,
        Activate,
        SubmitRound,
        BeginSettlement,
        Settle
    }

    error NotForwarder();
    error NotOwner();
    error NotSelf();
    error AlreadyInitialised();
    error NotNeeded();
    error ZeroAddress();

    uint256 internal constant LINEAR_LOOKBACK = 100;
    uint256 internal constant AGG_MASK = type(uint64).max;

    address public immutable owner;
    /// @notice Automation forwarder for this upkeep; only it may call performUpkeep.
    address public forwarder;
    uint256 public immutable minSamples;

    PricingEngine public engine;
    IOptionsVault public vault;
    SettlementResolver public resolver;
    AggregatorV3Interface public feed;

    event ForwarderSet(address indexed forwarder);
    event Initialised(
        address indexed engine, address indexed vault, address indexed resolver, address feed
    );
    event Performed(Action indexed action);
    event ActionFailed(Action indexed action);

    constructor(uint256 minSamples_) {
        owner = msg.sender;
        minSamples = minSamples_;
    }

    /// @notice One-time wiring: contracts reference this keeper, so it is deployed first.
    function init(
        PricingEngine engine_,
        IOptionsVault vault_,
        SettlementResolver resolver_,
        AggregatorV3Interface feed_
    ) external {
        if (msg.sender != owner) revert NotOwner();
        if (address(engine) != address(0)) revert AlreadyInitialised();
        if (
            address(engine_) == address(0) || address(vault_) == address(0)
                || address(resolver_) == address(0) || address(feed_) == address(0)
        ) revert ZeroAddress();
        engine = engine_;
        vault = vault_;
        resolver = resolver_;
        feed = feed_;
        emit Initialised(address(engine_), address(vault_), address(resolver_), address(feed_));
    }

    function setForwarder(address forwarder_) external {
        if (msg.sender != owner) revert NotOwner();
        forwarder = forwarder_;
        emit ForwarderSet(forwarder_);
    }

    // ------------------------------------------------------------------
    // Automation
    // ------------------------------------------------------------------

    function checkUpkeep(bytes calldata) external view returns (bool, bytes memory) {
        (Action a, bytes memory data) = _nextAction();
        return (a != Action.None, abi.encode(a, data));
    }

    function performUpkeep(bytes calldata) external {
        if (msg.sender != forwarder) revert NotForwarder();
        // Re-derive what is due right now; the simulated performData may be a block out of date.
        (Action a, bytes memory data) = _nextAction();
        if (a == Action.None) revert NotNeeded();

        try this.execute(a, data) {
            emit Performed(a);
        } catch (bytes memory reason) {
            emit ActionFailed(a);
            // Don't let a stuck lifecycle action starve the vol window.
            if (a != Action.Snapshot && _snapshotDue()) {
                this.execute(Action.Snapshot, "");
                emit Performed(Action.Snapshot);
            } else {
                // bubble the revert so Automation's simulation fails instead of sending a no-op
                assembly ("memory-safe") {
                    revert(add(reason, 0x20), mload(reason))
                }
            }
        }
    }

    /// @dev External only so `performUpkeep` can wrap it in try/catch. Not callable by others.
    function execute(Action a, bytes calldata data) external {
        if (msg.sender != address(this)) revert NotSelf();
        if (a == Action.Snapshot) {
            engine.recordSnapshot(resolver.spot());
        } else if (a == Action.StartEpoch) {
            vault.startEpoch();
        } else if (a == Action.Activate) {
            vault.activate();
        } else if (a == Action.SubmitRound) {
            resolver.submitExpiryRound(vault.currentEpoch(), abi.decode(data, (uint80)));
        } else if (a == Action.BeginSettlement) {
            vault.beginSettlement();
        } else if (a == Action.Settle) {
            vault.settle();
        }
    }

    /// @dev Lifecycle actions take priority over snapshots (they are rare and time-critical).
    function _nextAction() internal view returns (Action, bytes memory) {
        IOptionsVault.State s = vault.state();
        uint256 epoch = vault.currentEpoch();

        if (s == IOptionsVault.State.Settling) return (Action.Settle, "");

        if (s == IOptionsVault.State.Active) {
            IOptionsVault.Epoch memory e = vault.epochData(epoch);
            // strictly after expiry: the resolver refuses to record a price at block.timestamp == expiry
            if (block.timestamp > e.expiry) {
                try resolver.snapshotSettlementPrice(epoch) returns (uint256) {
                    return (Action.BeginSettlement, "");
                } catch {
                    (bool found, uint80 roundId) = _findExpiryRound(e.expiry);
                    if (found) return (Action.SubmitRound, abi.encode(roundId));
                }
            }
        } else if (s == IOptionsVault.State.Writing) {
            IOptionsVault.Epoch memory e = vault.epochData(epoch);
            if (e.optionsSold >= e.collateralLocked || block.timestamp > e.writingEnd) {
                return (Action.Activate, "");
            }
        } else if (s == IOptionsVault.State.Idle) {
            // Start only after the depositor exit window, with assets to lock, enough vol history,
            // a snapshot taken within the last interval (so vol is current), and a healthy oracle.
            if (
                block.timestamp >= vault.idleSince() + vault.idleWindow()
                    && IERC4626(address(vault)).totalAssets() > 0
                    && IERC4626(address(vault)).totalSupply() > 0
                    && engine.sampleCount() >= minSamples && !_snapshotDue() && _spotOk()
            ) {
                return (Action.StartEpoch, "");
            }
        }

        if (_snapshotDue() && _spotOk()) return (Action.Snapshot, "");
        return (Action.None, "");
    }

    function _snapshotDue() internal view returns (bool) {
        return block.timestamp >= engine.lastTimestamp() + engine.sampleInterval();
    }

    /// @dev The last round with updatedAt <= expiry. Cheap linear scan back from the latest round
    ///      covers the normal case; if the upkeep was delayed for long, binary search over the
    ///      aggregator round range of the latest phase (round timestamps are monotonic).
    function _findExpiryRound(uint256 expiry) internal view returns (bool, uint80) {
        (uint80 latest,,,,) = feed.latestRoundData();
        uint256 agg = uint256(latest) & AGG_MASK;
        for (uint256 i; i < LINEAR_LOOKBACK && i < agg; ++i) {
            uint80 id = latest - uint80(i);
            uint256 u = _updatedAt(id);
            if (u != 0 && u <= expiry) return (true, id);
        }

        uint256 base = uint256(latest) & ~AGG_MASK;
        uint256 lo = 1;
        uint256 hi = agg;
        if (hi == 0) return (false, 0);
        uint256 uLo = _updatedAt(uint80(base | lo));
        if (uLo == 0 || uLo > expiry) return (false, 0); // needs a previous phase; submit manually
        while (lo < hi) {
            uint256 mid = (lo + hi + 1) / 2;
            uint256 u = _updatedAt(uint80(base | mid));
            if (u != 0 && u <= expiry) lo = mid;
            else hi = mid - 1;
        }
        return (true, uint80(base | lo));
    }

    function _updatedAt(uint80 id) internal view returns (uint256) {
        try feed.getRoundData(id) returns (uint80, int256, uint256, uint256 u, uint80) {
            return u;
        } catch {
            return 0;
        }
    }

    function _spotOk() internal view returns (bool) {
        try resolver.spot() returns (uint256) {
            return true;
        } catch {
            return false;
        }
    }
}
