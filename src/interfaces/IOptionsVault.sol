// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice ERC-4626 covered-call vault over WETH with weekly epochs.
/// @dev Inherit IERC4626 in the implementation.
interface IOptionsVault {
    enum State {
        Idle,
        Writing,
        Active,
        Settling
    }

    struct Epoch {
        uint256 strike;
        uint256 expiry;
        uint256 collateralLocked;
        uint256 premiumCollected;
        uint256 settlementPrice;
    }

    error WrongState(State current);
    error NotKeeper();

    event EpochStarted(uint256 indexed epoch, uint256 strike, uint256 expiry, uint256 collateral);
    event OptionsPurchased(
        uint256 indexed epoch, address indexed buyer, uint256 amount, uint256 premium
    );
    event EpochSettled(uint256 indexed epoch, uint256 settlementPrice, uint256 payout);

    function state() external view returns (State);
    function currentEpoch() external view returns (uint256);
    function epochData(uint256 epoch) external view returns (Epoch memory);

    /// @notice Idle -> Writing: pick strike via PricingEngine, lock collateral.
    function startEpoch() external;

    /// @notice Writing -> Active: buyer pays USDC premium and receives OptionToken.
    function buyOptions(uint256 amount) external returns (uint256 premium);

    /// @notice Active -> Settling: snapshot settlement price after expiry.
    function beginSettlement() external;

    /// @notice Settling -> Idle: pay ITM holders, release remaining collateral.
    function settle() external;
}
