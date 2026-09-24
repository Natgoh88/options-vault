// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ISettlementResolver} from "../../src/interfaces/ISettlementResolver.sol";

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

/// Test double for the Chainlink-backed resolver (real one lands in Phase 3).
contract MockResolver is ISettlementResolver {
    uint256 public price;

    function setPrice(uint256 p) external {
        price = p;
    }

    function spot() external view returns (uint256) {
        return price;
    }

    function snapshotSettlementPrice(uint256 epoch) external returns (uint256) {
        emit SettlementPriceSet(epoch, price);
        return price;
    }

    function payoutPerOption(uint256, uint256 strike) external view returns (uint256) {
        return price > strike ? (price - strike) * 1e18 / price : 0;
    }
}
