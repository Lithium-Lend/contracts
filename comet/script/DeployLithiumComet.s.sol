// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.15;

import {Script} from "forge-std/Script.sol";
import {LithiumComet} from "../src/LithiumComet.sol";
import {LithiumCometPriceFeed} from "../src/LithiumCometPriceFeed.sol";
import {CometConfiguration} from "comet/CometConfiguration.sol";
import {CometExt} from "comet/CometExt.sol";
import {IPriceFeed} from "comet/interfaces/IPriceFeed.sol";
import {IERC20NonStandard} from "comet/interfaces/IERC20NonStandard.sol";
import {ProxyAdmin} from "comet/vendor/proxy/transparent/ProxyAdmin.sol";
import {TransparentUpgradeableProxy} from "comet/vendor/proxy/transparent/TransparentUpgradeableProxy.sol";

/// @notice Explicit-input LiteForge deployment. No assets or live risk parameters are guessed.
contract DeployLithiumComet is Script {
    error WrongChain();
    error InvalidInput();
    event Deployment(address comet, address implementation, address proxyAdmin, address baseToken);

    function run() external returns (LithiumComet comet) {
        if (block.chainid != 4441 || vm.envUint("EXPECTED_CHAIN_ID") != block.chainid) revert WrongChain();
        // LiteForge's deployed DIA receiver is compiled for Prague. Simulate
        // its opcodes without changing Comet's London-compatible bytecode.
        vm.setEvmVersion("prague");
        CometConfiguration.Configuration memory config;
        config.governor = vm.envAddress("COMET_GOVERNOR");
        config.pauseGuardian = vm.envAddress("COMET_PAUSE_GUARDIAN");
        address upgradeOwner = vm.envAddress("COMET_UPGRADE_OWNER");
        config.baseToken = vm.envAddress("COMET_USDC_ADDRESS");
        address usdSource = vm.envAddress("COMET_USDC_USD_FEED");
        address ltcSource = vm.envAddress("COMET_ZKLTC_USD_FEED");
        uint256 usdAge = vm.envUint("COMET_USDC_MAX_STALENESS");
        uint256 ltcAge = vm.envUint("COMET_ZKLTC_MAX_STALENESS");
        if (
            config.governor == address(0) || config.pauseGuardian == address(0) || upgradeOwner == address(0)
                || config.baseToken.code.length == 0 || IERC20NonStandard(config.baseToken).decimals() != 6
        ) revert InvalidInput();
        validateFeed(usdSource, usdAge);
        validateFeed(ltcSource, ltcAge);
        config.supplyKink = uint64(input("COMET_SUPPLY_KINK", type(uint64).max));
        config.supplyPerYearInterestRateSlopeLow = uint64(input("COMET_SUPPLY_SLOPE_LOW", type(uint64).max));
        config.supplyPerYearInterestRateSlopeHigh = uint64(input("COMET_SUPPLY_SLOPE_HIGH", type(uint64).max));
        config.supplyPerYearInterestRateBase = uint64(input("COMET_SUPPLY_RATE_BASE", type(uint64).max));
        config.borrowKink = uint64(input("COMET_BORROW_KINK", type(uint64).max));
        config.borrowPerYearInterestRateSlopeLow = uint64(input("COMET_BORROW_SLOPE_LOW", type(uint64).max));
        config.borrowPerYearInterestRateSlopeHigh = uint64(input("COMET_BORROW_SLOPE_HIGH", type(uint64).max));
        config.borrowPerYearInterestRateBase = uint64(input("COMET_BORROW_RATE_BASE", type(uint64).max));
        config.storeFrontPriceFactor = uint64(input("COMET_STOREFRONT_FACTOR", 1e18));
        config.baseBorrowMin = uint104(input("COMET_MINIMUM_BORROW", type(uint104).max));
        config.targetReserves = uint104(input("COMET_TARGET_RESERVES", type(uint104).max));
        // Rewards are disabled. Scales remain valid for upstream index calculations.
        config.trackingIndexScale = 1e15;
        config.baseMinForRewards = 1e6;
        config.assetConfigs = new CometConfiguration.AssetConfig[](1);
        config.assetConfigs[0] = CometConfiguration.AssetConfig({
            asset: address(0),
            priceFeed: address(0),
            decimals: 18,
            borrowCollateralFactor: uint64(input("COMET_BORROW_COLLATERAL_FACTOR", 1e18)),
            liquidateCollateralFactor: uint64(input("COMET_LIQUIDATION_COLLATERAL_FACTOR", 1e18)),
            liquidationFactor: uint64(input("COMET_LIQUIDATION_FACTOR", 1e18)),
            supplyCap: uint128(input("COMET_ZKLTC_SUPPLY_CAP", type(uint128).max))
        });
        if (
            config.baseBorrowMin == 0 || config.targetReserves == 0 || config.supplyKink > 1e18
                || config.borrowKink > 1e18 || config.assetConfigs[0].supplyCap == 0
                || config.assetConfigs[0].borrowCollateralFactor == 0
                || config.assetConfigs[0].borrowCollateralFactor >= config.assetConfigs[0].liquidateCollateralFactor
                || config.assetConfigs[0].liquidationFactor == 0
        ) revert InvalidInput();

        // Use Foundry's keystore or hardware-wallet signer. No private-key environment variable is read.
        vm.startBroadcast();
        config.baseTokenPriceFeed = address(new LithiumCometPriceFeed(usdSource, usdAge));
        config.assetConfigs[0].priceFeed = address(new LithiumCometPriceFeed(ltcSource, ltcAge));
        config.extensionDelegate =
            address(new CometExt(CometConfiguration.ExtConfiguration(bytes32("Lithium USDC"), bytes32("liUSDC"))));
        ProxyAdmin admin = new ProxyAdmin(upgradeOwner);
        LithiumComet implementation = new LithiumComet(config);
        // Initialize proxy storage atomically, leaving no externally callable initialization window.
        comet = LithiumComet(
            payable(address(
                    new TransparentUpgradeableProxy(
                        address(implementation), address(admin), abi.encodeWithSignature("initializeStorage()")
                    )
                ))
        );
        vm.stopBroadcast();
        emit Deployment(address(comet), address(implementation), address(admin), config.baseToken);
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
