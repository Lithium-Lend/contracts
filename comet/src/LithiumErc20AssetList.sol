// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.15;

import {CometCore} from "comet/CometCore.sol";
import {CometConfiguration} from "comet/CometConfiguration.sol";
import {IERC20NonStandard} from "comet/interfaces/IERC20NonStandard.sol";
import {IPriceFeed} from "comet/interfaces/IPriceFeed.sol";

/// @notice Immutable single-USDC collateral configuration for the native zkLTC-base market.
contract LithiumErc20AssetList {
    uint8 public constant numAssets = 1;
    address public immutable asset;
    address public immutable priceFeed;
    uint64 public immutable borrowCollateralFactor;
    uint64 public immutable liquidateCollateralFactor;
    uint64 public immutable liquidationFactor;
    uint128 public immutable supplyCap;

    error InvalidCollateral();

    constructor(CometConfiguration.AssetConfig memory config) {
        if (
            config.asset.code.length == 0 || config.decimals != 6 || IERC20NonStandard(config.asset).decimals() != 6
                || config.supplyCap == 0 || config.priceFeed.code.length == 0
                || IPriceFeed(config.priceFeed).decimals() != 8 || config.borrowCollateralFactor == 0
                || config.borrowCollateralFactor >= config.liquidateCollateralFactor
                || config.liquidateCollateralFactor > 1e18 || config.liquidationFactor == 0
                || config.liquidationFactor > 1e18
        ) revert InvalidCollateral();
        asset = config.asset;
        priceFeed = config.priceFeed;
        borrowCollateralFactor = config.borrowCollateralFactor;
        liquidateCollateralFactor = config.liquidateCollateralFactor;
        liquidationFactor = config.liquidationFactor;
        supplyCap = config.supplyCap;
    }

    function getAssetInfo(uint8 index) external view returns (CometCore.AssetInfo memory) {
        if (index != 0) revert InvalidCollateral();
        return CometCore.AssetInfo({
            offset: 0,
            asset: asset,
            priceFeed: priceFeed,
            scale: 1e6,
            borrowCollateralFactor: borrowCollateralFactor,
            liquidateCollateralFactor: liquidateCollateralFactor,
            liquidationFactor: liquidationFactor,
            supplyCap: supplyCap
        });
    }
}
