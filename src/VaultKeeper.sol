// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
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
/// @dev `checkUpkeep` runs off-chain (simulated); `performUpkeep` re-validates every condition so
///      a forged `performData` can at worst trigger an action that was legitimately due.
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
    error AlreadyInitialised();
    error NotNeeded();

    uint256 internal constant MAX_ROUND_LOOKBACK = 100;

    address public immutable owner;
    /// @notice Automation forwarder for this upkeep; only it may call performUpkeep.
    address public forwarder;
    uint256 public immutable minSamples;

    PricingEngine public engine;
    IOptionsVault public vault;
    SettlementResolver public resolver;
    AggregatorV3Interface public feed;

    event ForwarderSet(address indexed forwarder);
    event Performed(Action indexed action);

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
        engine = engine_;
        vault = vault_;
        resolver = resolver_;
        feed = feed_;
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

    function performUpkeep(bytes calldata performData) external {
        if (msg.sender != forwarder) revert NotForwarder();
        (Action a, bytes memory data) = abi.decode(performData, (Action, bytes));
        // Re-derive what is due right now and require the request to match it.
        (Action due, bytes memory dueData) = _nextAction();
        if (a == Action.None || a != due || keccak256(data) != keccak256(dueData)) {
            revert NotNeeded();
        }

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
        emit Performed(a);
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
            if (
                IERC4626(address(vault)).totalAssets() > 0 && engine.sampleCount() >= minSamples
                    && _spotOk()
            ) {
                return (Action.StartEpoch, "");
            }
        }

        if (block.timestamp >= engine.lastTimestamp() + engine.sampleInterval() && _spotOk()) {
            return (Action.Snapshot, "");
        }
        return (Action.None, "");
    }

    /// @dev Walks back from the latest round to the last round with updatedAt <= expiry.
    function _findExpiryRound(uint256 expiry) internal view returns (bool, uint80) {
        (uint80 latest,,,,) = feed.latestRoundData();
        for (uint256 i; i < MAX_ROUND_LOOKBACK && i <= latest; ++i) {
            uint80 id = latest - uint80(i);
            try feed.getRoundData(id) returns (uint80, int256, uint256, uint256 u, uint80) {
                if (u != 0 && u <= expiry) return (true, id);
            } catch {}
        }
        return (false, 0);
    }

    function _spotOk() internal view returns (bool) {
        try resolver.spot() returns (uint256) {
            return true;
        } catch {
            return false;
        }
    }
}
