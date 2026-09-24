// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PricingEngine} from "../src/PricingEngine.sol";
import {OptionToken} from "../src/OptionToken.sol";
import {OptionsVault} from "../src/OptionsVault.sol";
import {SettlementResolver} from "../src/SettlementResolver.sol";
import {VaultKeeper} from "../src/VaultKeeper.sol";
import {TestUSDC} from "../src/testnet/TestUSDC.sol";
import {IOptionsVault} from "../src/interfaces/IOptionsVault.sol";
import {IPricingEngine} from "../src/interfaces/IPricingEngine.sol";
import {IOptionToken} from "../src/interfaces/IOptionToken.sol";
import {ISettlementResolver} from "../src/interfaces/ISettlementResolver.sol";
import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";

/// @notice Deploys and wires the whole system.
///
///   forge script script/Deploy.s.sol --rpc-url arbitrum_sepolia --account <keystore> --broadcast
///
/// Nothing secret is read from the environment: the deployer signs from an encrypted keystore
/// (`cast wallet import`). Env vars below only carry public parameters.
///
///   PROFILE   "demo" (default, hours-long epochs so the lifecycle is watchable on a testnet)
///             or "weekly" (the production cadence from the design: 7-day epochs)
///   WETH, FEED, SEQUENCER_FEED, USDC   override addresses (USDC unset => deploy TestUSDC)
contract Deploy is Script {
    // Arbitrum Sepolia (chain 421614). Verified on-chain: FEED.description() == "ETH / USD",
    // decimals 8; WETH.symbol() == "WETH".
    address constant SEPOLIA_WETH = 0x980B62Da83eFf3D4576C647993b0c1D7faf17c73;
    address constant SEPOLIA_ETH_USD = 0xd30e2101a97dcbAeBCBC04F14C3f624E67A35165;

    struct Profile {
        uint256 sampleInterval;
        uint256 windowSize;
        uint256 minSamples;
        uint256 heartbeat;
        uint256 heartbeatBuffer;
        uint256 fallbackDelay;
        OptionsVault.Params vault;
    }

    struct Deployed {
        VaultKeeper keeper;
        PricingEngine engine;
        SettlementResolver resolver;
        OptionToken token;
        OptionsVault vault;
        address weth;
        address usdc;
        address feed;
    }

    uint256 constant RISK_FREE = 0.04e18;
    uint256 constant MIN_VOL = 0.4e18;
    uint256 constant MAX_VOL = 3e18;

    /// Entry point for `forge script`: reads public parameters from the environment.
    function run() external returns (Deployed memory) {
        return deployWith(
            vm.envOr("PROFILE", string("demo")),
            vm.envOr("WETH", SEPOLIA_WETH),
            vm.envOr("FEED", SEPOLIA_ETH_USD),
            vm.envOr("SEQUENCER_FEED", address(0)), // no sequencer feed on Sepolia
            vm.envOr("USDC", address(0))
        );
    }

    /// The deployment itself, parameterised so tests can call it without touching process env
    /// (tests run in parallel and `vm.setEnv` is process-global).
    function deployWith(
        string memory profile,
        address weth,
        address feed,
        address seq,
        address usdc
    ) public returns (Deployed memory d) {
        Profile memory p = _profile(profile);

        vm.startBroadcast();

        if (usdc == address(0)) usdc = address(new TestUSDC());

        d.keeper = new VaultKeeper(p.minSamples);
        d.engine = new PricingEngine(
            address(d.keeper), p.sampleInterval, p.windowSize, int256(RISK_FREE), MIN_VOL, MAX_VOL
        );
        d.resolver = new SettlementResolver(
            AggregatorV3Interface(feed),
            AggregatorV3Interface(seq),
            p.heartbeat,
            p.heartbeatBuffer,
            1 hours, // sequencer grace period (unused when no sequencer feed)
            p.fallbackDelay
        );
        d.token = new OptionToken();
        d.vault = new OptionsVault(
            IERC20(weth),
            IERC20(usdc),
            IPricingEngine(address(d.engine)),
            ISettlementResolver(address(d.resolver)),
            IOptionToken(address(d.token)),
            address(d.keeper),
            p.vault
        );

        // one-shot wiring (the contracts reference each other)
        d.token.setVault(address(d.vault));
        d.resolver.setVault(IOptionsVault(address(d.vault)));
        d.keeper
            .init(
                d.engine, IOptionsVault(address(d.vault)), d.resolver, AggregatorV3Interface(feed)
            );
        vm.stopBroadcast();

        d.weth = weth;
        d.usdc = usdc;
        d.feed = feed;
        address deployer = d.vault.owner(); // the broadcasting account
        _write(d, deployer, p);
        _log(d, deployer);
    }

    function _profile(string memory name) internal pure returns (Profile memory p) {
        if (keccak256(bytes(name)) == keccak256("weekly")) {
            p.sampleInterval = 1 hours;
            p.windowSize = 168; // one week of hourly samples
            p.minSamples = 24;
            p.heartbeat = 1 days;
            p.heartbeatBuffer = 1 hours;
            p.fallbackDelay = 2 days;
            p.vault = OptionsVault.Params({
                epochDuration: 7 days,
                writingWindow: 6 hours,
                idleWindow: 1 days,
                targetDelta: 0.3e18,
                maxSpotDeviationBps: 100,
                premiumMarkupBps: 200
            });
        } else {
            // "demo": everything compressed so a full epoch completes in ~7 hours. The Sepolia
            // ETH/USD feed updates about every 2 minutes and is noisy, hence the wider band.
            p.sampleInterval = 10 minutes;
            p.windowSize = 36; // 6 hours of samples
            p.minSamples = 6;
            p.heartbeat = 1 hours;
            p.heartbeatBuffer = 30 minutes;
            p.fallbackDelay = 6 hours;
            p.vault = OptionsVault.Params({
                epochDuration: 6 hours,
                writingWindow: 30 minutes,
                idleWindow: 30 minutes,
                targetDelta: 0.3e18,
                maxSpotDeviationBps: 300,
                premiumMarkupBps: 200
            });
        }
    }

    function _write(Deployed memory d, address deployer, Profile memory p) internal {
        string memory k = "deployment";
        vm.serializeUint(k, "chainId", block.chainid);
        vm.serializeAddress(k, "deployer", deployer);
        vm.serializeAddress(k, "vault", address(d.vault));
        vm.serializeAddress(k, "engine", address(d.engine));
        vm.serializeAddress(k, "resolver", address(d.resolver));
        vm.serializeAddress(k, "optionToken", address(d.token));
        vm.serializeAddress(k, "keeper", address(d.keeper));
        vm.serializeAddress(k, "weth", d.weth);
        vm.serializeAddress(k, "usdc", d.usdc);
        vm.serializeAddress(k, "feed", d.feed);
        vm.serializeUint(k, "epochDuration", p.vault.epochDuration);
        vm.serializeUint(k, "writingWindow", p.vault.writingWindow);
        vm.serializeUint(k, "idleWindow", p.vault.idleWindow);
        vm.serializeUint(k, "targetDelta", p.vault.targetDelta);
        string memory json = vm.serializeUint(k, "deployBlock", block.number);
        vm.writeJson(json, string.concat("./deployments/", vm.toString(block.chainid), ".json"));
    }

    function _log(Deployed memory d, address deployer) internal pure {
        console.log("== Options Vault deployed ==");
        console.log("deployer     ", deployer);
        console.log("vault        ", address(d.vault));
        console.log("engine       ", address(d.engine));
        console.log("resolver     ", address(d.resolver));
        console.log("optionToken  ", address(d.token));
        console.log("keeper       ", address(d.keeper));
        console.log("usdc         ", d.usdc);
        console.log("");
        console.log("Next: register a Chainlink Automation upkeep (custom logic) targeting the");
        console.log("keeper address, then call keeper.setForwarder(<upkeep forwarder>).");
    }
}
