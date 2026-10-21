// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.15;

import {Script} from "forge-std/Script.sol";
import {LithiumUSDTComet} from "../src/LithiumUSDTComet.sol";
import {LithiumNativeBaseComet} from "../src/LithiumNativeBaseComet.sol";
import {LithiumCometPriceFeed} from "../src/LithiumCometPriceFeed.sol";
import {CometConfiguration} from "comet/CometConfiguration.sol";
import {CometMainInterface} from "comet/CometMainInterface.sol";
import {CometExt} from "comet/CometExt.sol";
import {IPriceFeed} from "comet/interfaces/IPriceFeed.sol";
import {IERC20NonStandard} from "comet/interfaces/IERC20NonStandard.sol";
import {ProxyAdmin} from "comet/vendor/proxy/transparent/ProxyAdmin.sol";
import {TransparentUpgradeableProxy} from "comet/vendor/proxy/transparent/TransparentUpgradeableProxy.sol";

/// @notice Independent LiteForge markets, with explicit input and atomic initialization.
abstract contract AdditionalMarketDeployment is Script {
    error WrongChain();
    error InvalidInput();
    event Deployment(address comet, address implementation, address proxyAdmin, address base, address collateral);

    function nativeBase() internal pure virtual returns (bool);
    function implementation(CometConfiguration.Configuration memory config) internal virtual returns (address);

    function run() external returns (CometMainInterface market) {
        if (block.chainid != 4441 || vm.envUint("MARKET_EXPECTED_CHAIN_ID") != block.chainid) revert WrongChain();
        vm.setEvmVersion("prague");
        bool isNative = nativeBase();
        CometConfiguration.Configuration memory c;
        c.governor = vm.envAddress("MARKET_GOVERNOR");
        c.pauseGuardian = vm.envAddress("MARKET_PAUSE_GUARDIAN");
        address upgradeOwner = vm.envAddress("MARKET_UPGRADE_OWNER");
        c.baseToken = vm.envAddress("MARKET_BASE_TOKEN");
        address collateral = vm.envAddress("MARKET_COLLATERAL_TOKEN");
        address baseSource = vm.envAddress("MARKET_BASE_USD_FEED");
        address collateralSource = vm.envAddress("MARKET_COLLATERAL_USD_FEED");
        uint256 baseAge = vm.envUint("MARKET_BASE_MAX_STALENESS");
        uint256 collateralAge = vm.envUint("MARKET_COLLATERAL_MAX_STALENESS");
        address token = isNative ? collateral : c.baseToken;
        if (
            c.governor == address(0) || c.pauseGuardian == address(0) || upgradeOwner == address(0)
                || token.code.length == 0 || IERC20NonStandard(token).decimals() != 6
                || (isNative ? c.baseToken != address(0) : collateral != address(0))
        ) revert InvalidInput();
        validateFeed(baseSource, baseAge);
        validateFeed(collateralSource, collateralAge);
        c.supplyKink = uint64(input("MARKET_SUPPLY_KINK", 1e18));
        c.supplyPerYearInterestRateSlopeLow = uint64(input("MARKET_SUPPLY_SLOPE_LOW", type(uint64).max));
        c.supplyPerYearInterestRateSlopeHigh = uint64(input("MARKET_SUPPLY_SLOPE_HIGH", type(uint64).max));
        c.supplyPerYearInterestRateBase = uint64(input("MARKET_SUPPLY_RATE_BASE", type(uint64).max));
        c.borrowKink = uint64(input("MARKET_BORROW_KINK", 1e18));
        c.borrowPerYearInterestRateSlopeLow = uint64(input("MARKET_BORROW_SLOPE_LOW", type(uint64).max));
        c.borrowPerYearInterestRateSlopeHigh = uint64(input("MARKET_BORROW_SLOPE_HIGH", type(uint64).max));
        c.borrowPerYearInterestRateBase = uint64(input("MARKET_BORROW_RATE_BASE", type(uint64).max));
        c.storeFrontPriceFactor = uint64(input("MARKET_STOREFRONT_FACTOR", 1e18));
        c.baseBorrowMin = uint104(input("MARKET_MINIMUM_BORROW", type(uint104).max));
        c.targetReserves = uint104(input("MARKET_TARGET_RESERVES", type(uint104).max));
        c.trackingIndexScale = 1e15;
        c.baseMinForRewards = isNative ? 1e18 : 1e6;
        c.assetConfigs = new CometConfiguration.AssetConfig[](1);
        c.assetConfigs[0] = CometConfiguration.AssetConfig({
            asset: collateral,
            priceFeed: address(0),
            decimals: isNative ? 6 : 18,
            borrowCollateralFactor: uint64(input("MARKET_BORROW_COLLATERAL_FACTOR", 1e18)),
            liquidateCollateralFactor: uint64(input("MARKET_LIQUIDATION_COLLATERAL_FACTOR", 1e18)),
            liquidationFactor: uint64(input("MARKET_LIQUIDATION_FACTOR", 1e18)),
            supplyCap: uint128(input("MARKET_COLLATERAL_SUPPLY_CAP", type(uint128).max))
        });
        if (
            c.baseBorrowMin == 0 || c.targetReserves == 0 || c.assetConfigs[0].supplyCap == 0
                || c.assetConfigs[0].borrowCollateralFactor == 0
                || c.assetConfigs[0].borrowCollateralFactor >= c.assetConfigs[0].liquidateCollateralFactor
                || c.assetConfigs[0].liquidationFactor == 0
        ) revert InvalidInput();

        // Signer selection is external to the script. Never read a private-key environment variable.
        vm.startBroadcast();
        c.baseTokenPriceFeed = address(new LithiumCometPriceFeed(baseSource, baseAge));
        c.assetConfigs[0].priceFeed = address(new LithiumCometPriceFeed(collateralSource, collateralAge));
        c.extensionDelegate = address(
            new CometExt(
                CometConfiguration.ExtConfiguration(
                    isNative ? bytes32("Lithium zkLTC") : bytes32("Lithium USDT"),
                    isNative ? bytes32("lizkLTC") : bytes32("liUSDT")
                )
            )
        );
        ProxyAdmin admin = new ProxyAdmin(upgradeOwner);
        address core = implementation(c);
        market = CometMainInterface(
            address(
                new TransparentUpgradeableProxy(core, address(admin), abi.encodeWithSignature("initializeStorage()"))
            )
        );
        vm.stopBroadcast();
        emit Deployment(address(market), core, address(admin), c.baseToken, collateral);
    }

    function input(string memory key, uint256 max) internal view returns (uint256 value) {
        value = vm.envUint(key);
        if (value > max) revert InvalidInput();
    }

    function validateFeed(address feed, uint256 age) internal view {
        if (feed.code.length == 0 || age == 0 || IPriceFeed(feed).decimals() > 36) revert InvalidInput();
        (uint80 round, int256 price,, uint256 updated, uint80 answered) = IPriceFeed(feed).latestRoundData();
        if (
            price <= 0 || updated == 0 || updated > block.timestamp || block.timestamp - updated > age
                || answered < round
        ) revert InvalidInput();
        uint8 decimals_ = IPriceFeed(feed).decimals();
        if (decimals_ > 8 && price / int256(10 ** uint256(decimals_ - 8)) == 0) revert InvalidInput();
        if (decimals_ < 8 && price > type(int256).max / int256(10 ** uint256(8 - decimals_))) revert InvalidInput();
    }
}

contract DeployLithiumUSDTComet is AdditionalMarketDeployment {
    function nativeBase() internal pure override returns (bool) {
        return false;
    }

    function implementation(CometConfiguration.Configuration memory c) internal override returns (address) {
        return address(new LithiumUSDTComet(c));
    }
}

contract DeployLithiumNativeBaseComet is AdditionalMarketDeployment {
    function nativeBase() internal pure override returns (bool) {
        return true;
    }

    function implementation(CometConfiguration.Configuration memory c) internal override returns (address) {
        return address(new LithiumNativeBaseComet(c));
    }
}
