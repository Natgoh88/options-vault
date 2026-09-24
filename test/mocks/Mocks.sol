// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ISettlementResolver} from "../../src/interfaces/ISettlementResolver.sol";
import {AggregatorV3Interface} from "../../src/interfaces/AggregatorV3Interface.sol";

contract MockERC20 is ERC20 {
    uint8 internal immutable _dec;

    constructor(string memory n, string memory s, uint8 d) ERC20(n, s) {
        _dec = d;
    }

    function decimals() public view override returns (uint8) {
        return _dec;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// Simple test double for the resolver, used by vault-only tests.
contract MockResolver is ISettlementResolver {
    uint256 public price;

    function setPrice(uint256 p) external {
        price = p;
    }

    function spot() external view returns (uint256) {
        return price;
    }

    function submitExpiryRound(uint256, uint80) external view returns (uint256) {
        return price;
    }

    function snapshotSettlementPrice(uint256) external view returns (uint256) {
        return price;
    }

    function payoutPerOption(uint256, uint256 strike) external view returns (uint256) {
        return price > strike ? (price - strike) * 1e18 / price : 0;
    }
}

/// Chainlink aggregator double with a full round history.
contract MockAggregator is AggregatorV3Interface {
    struct Round {
        int256 answer;
        uint256 startedAt;
        uint256 updatedAt;
    }

    uint8 public immutable decimals;
    uint80 public latestId;
    mapping(uint80 => Round) public rounds;

    constructor(uint8 d) {
        decimals = d;
    }

    /// Append a round updated at `updatedAt` (defaults: block.timestamp).
    function push(int256 answer) external {
        _push(answer, block.timestamp);
    }

    function pushAt(int256 answer, uint256 updatedAt) external {
        _push(answer, updatedAt);
    }

    function _push(int256 answer, uint256 updatedAt) internal {
        ++latestId;
        rounds[latestId] = Round(answer, updatedAt, updatedAt);
    }

    function getRoundData(uint80 id)
        external
        view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        Round memory r = rounds[id];
        require(r.updatedAt != 0, "No data present");
        return (id, r.answer, r.startedAt, r.updatedAt, id);
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        Round memory r = rounds[latestId];
        return (latestId, r.answer, r.startedAt, r.updatedAt, latestId);
    }
}
