// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.15;

import {LithiumCometFixture} from "./LithiumComet.t.sol";
import {LithiumComet} from "../src/LithiumComet.sol";
import {LithiumCometPriceFeed} from "../src/LithiumCometPriceFeed.sol";
import {TransparentUpgradeableProxy} from "comet/vendor/proxy/transparent/TransparentUpgradeableProxy.sol";

/// @dev Exercise the actual deployment JSON, not separately chosen unit fixtures.
contract LiteForgeConfigurationTest is LithiumCometFixture {
    string internal proposal;
    string internal snapshot;

    function value(string memory key) internal view returns (uint256) {
        return vm.parseUint(vm.parseJsonString(proposal, string.concat(".environment.", key)));
    }

    function referenceValue(string memory key) internal view returns (uint256) {
        return vm.parseUint(vm.parseJsonString(snapshot, string.concat(".", key)));
    }

    function setUp() public override {
        super.setUp();
        proposal = vm.readFile("config/liteforge.proposed.json");
        snapshot = vm.readFile("config/compound-mainnet-usdc.snapshot.json");
        usdFeed = new LithiumCometPriceFeed(address(usdSource), value("COMET_USDC_MAX_STALENESS"));
        ltcFeed = new LithiumCometPriceFeed(address(ltcSource), value("COMET_ZKLTC_MAX_STALENESS"));
        config.baseTokenPriceFeed = address(usdFeed);
        config.supplyKink = uint64(value("COMET_SUPPLY_KINK"));
        config.borrowKink = uint64(value("COMET_BORROW_KINK"));
        config.supplyPerYearInterestRateBase = uint64(value("COMET_SUPPLY_RATE_BASE"));
        config.supplyPerYearInterestRateSlopeLow = uint64(value("COMET_SUPPLY_SLOPE_LOW"));
        config.supplyPerYearInterestRateSlopeHigh = uint64(value("COMET_SUPPLY_SLOPE_HIGH"));
        config.borrowPerYearInterestRateBase = uint64(value("COMET_BORROW_RATE_BASE"));
        config.borrowPerYearInterestRateSlopeLow = uint64(value("COMET_BORROW_SLOPE_LOW"));
        config.borrowPerYearInterestRateSlopeHigh = uint64(value("COMET_BORROW_SLOPE_HIGH"));
        config.storeFrontPriceFactor = uint64(value("COMET_STOREFRONT_FACTOR"));
        config.baseBorrowMin = uint104(value("COMET_MINIMUM_BORROW"));
        config.targetReserves = uint104(value("COMET_TARGET_RESERVES"));
        config.assetConfigs[0].priceFeed = address(ltcFeed);
        config.assetConfigs[0].borrowCollateralFactor = uint64(value("COMET_BORROW_COLLATERAL_FACTOR"));
        config.assetConfigs[0].liquidateCollateralFactor = uint64(value("COMET_LIQUIDATION_COLLATERAL_FACTOR"));
        config.assetConfigs[0].liquidationFactor = uint64(value("COMET_LIQUIDATION_FACTOR"));
        config.assetConfigs[0].supplyCap = uint128(value("COMET_ZKLTC_SUPPLY_CAP"));
        implementation = deployCode("LithiumComet.sol:LithiumComet", abi.encode(config));
        comet = LithiumComet(
            payable(address(
                    new TransparentUpgradeableProxy(
                        implementation, proxyAdmin, abi.encodeWithSignature("initializeStorage()")
                    )
                ))
        );
        usdc.approve(address(comet), type(uint256).max);
        comet.supply(address(usdc), 1000e6);
        vm.prank(alice);
        usdc.approve(address(comet), type(uint256).max);
    }

    function testConfiguredRatesExactlyMatchLiveCompoundSnapshot() public view {
        assertEq(comet.supplyKink(), referenceValue("supplyKink"));
        assertEq(comet.borrowKink(), referenceValue("borrowKink"));
        assertEq(comet.supplyPerSecondInterestRateBase(), referenceValue("supplyPerSecondInterestRateBase"));
        assertEq(comet.supplyPerSecondInterestRateSlopeLow(), referenceValue("supplyPerSecondInterestRateSlopeLow"));
        assertEq(comet.supplyPerSecondInterestRateSlopeHigh(), referenceValue("supplyPerSecondInterestRateSlopeHigh"));
        assertEq(comet.borrowPerSecondInterestRateBase(), referenceValue("borrowPerSecondInterestRateBase"));
        assertEq(comet.borrowPerSecondInterestRateSlopeLow(), referenceValue("borrowPerSecondInterestRateSlopeLow"));
        assertEq(comet.borrowPerSecondInterestRateSlopeHigh(), referenceValue("borrowPerSecondInterestRateSlopeHigh"));
    }

    function testSelectedTestnetFactorsAndRetainedCompoundLiquidationPricing() public view {
        assertEq(comet.getAssetInfo(0).borrowCollateralFactor, 6e17);
        assertEq(comet.getAssetInfo(0).liquidateCollateralFactor, 7e17);
        assertLt(config.assetConfigs[0].borrowCollateralFactor, referenceValue("WBTC.borrowCollateralFactor"));
        assertLt(config.assetConfigs[0].liquidateCollateralFactor, referenceValue("WBTC.liquidateCollateralFactor"));
        assertEq(config.assetConfigs[0].liquidationFactor, referenceValue("WBTC.liquidationFactor"));
        assertEq(comet.storeFrontPriceFactor(), referenceValue("storeFrontPriceFactor"));
        // Native asset identity and test-sized caps deliberately differ from WBTC.
        assertEq(comet.getAssetInfo(0).asset, address(0));
        assertEq(comet.getAssetInfo(0).supplyCap, 10 ether);
        assertEq(comet.baseBorrowMin(), 1e5);
        assertEq(comet.targetReserves(), 10e6);
    }

    function testBorrowLimitAndLiquidationThresholdUseConfiguredFactors() public {
        deposit(alice, 2 ether);
        borrow(120e6); // Exact 60% borrowing limit on 200 USD collateral.
        vm.prank(alice);
        vm.expectRevert();
        comet.withdraw(address(usdc), 1e6);
        assertFalse(comet.isLiquidatable(alice));
        ltcSource.set(86e8); // 172 USD collateral * 70% = 120.4 USD.
        assertFalse(comet.isLiquidatable(alice));
        ltcSource.set(85e8); // 170 USD collateral * 70% = 119 USD.
        assertTrue(comet.isLiquidatable(alice));
    }

    function testSelectedThresholdDoesNotHideDelayedSaleReserveLoss() public {
        deposit(alice, 2 ether);
        borrow(120e6);
        ltcSource.set(85e8);
        address[] memory accounts = new address[](1);
        accounts[0] = alice;
        int256 reservesBefore = comet.getReserves();
        comet.absorb(bob, accounts);
        // 170 USD collateral * 90% = 153 USDC reserve charge, including
        // the former borrower's new supply balance. Then a 5% price decline.
        ltcSource.set(8075e6);
        comet.buyCollateral(address(0), 2 ether, 151_810_000, address(this));
        assertApproxEqAbs(comet.getReserves() - reservesBefore, -int256(1_190_000), 5);
        assertEq(comet.getCollateralReserves(address(0)), 0);
    }

    receive() external payable {}

    function testLiquidationSaleDiscountIsSixPercent() public view {
        // 100 USD/zkLTC at a 6% discount: 94 USDC buys one zkLTC.
        assertEq(comet.quoteCollateral(address(0), 94e6), 1 ether);
    }

    function testDiaHeartbeatBoundaryForBothFeeds() public {
        assertEq(usdFeed.maxStaleness(), 1 hours);
        assertEq(ltcFeed.maxStaleness(), 1 hours);
        vm.warp(block.timestamp + 1 hours);
        usdFeed.latestRoundData();
        ltcFeed.latestRoundData();
        vm.warp(block.timestamp + 1);
        vm.expectRevert(LithiumCometPriceFeed.InvalidPrice.selector);
        usdFeed.latestRoundData();
        vm.expectRevert(LithiumCometPriceFeed.InvalidPrice.selector);
        ltcFeed.latestRoundData();
        refresh();
        usdFeed.latestRoundData();
        ltcFeed.latestRoundData();
    }

    function testDiaAddressesAndPublishedUpdateSettings() public view {
        string memory assets = vm.readFile("config/liteforge-assets.json");
        assertEq(vm.parseJsonUint(assets, ".priceSources.heartbeatSeconds"), value("COMET_USDC_MAX_STALENESS"));
        assertEq(vm.parseJsonUint(assets, ".priceSources.stablecoinDeviationBps"), 50);
        assertEq(vm.parseJsonUint(assets, ".priceSources.otherAssetDeviationBps"), 100);
        assertEq(
            vm.parseJsonAddress(proposal, ".environment.COMET_USDC_USD_FEED"),
            vm.parseJsonAddress(assets, ".priceSources.USDC_USD")
        );
        assertEq(
            vm.parseJsonAddress(proposal, ".environment.COMET_ZKLTC_USD_FEED"),
            vm.parseJsonAddress(assets, ".priceSources.LTC_USD")
        );
    }

    function testCopiedCurveRetainsLowUtilizationReserveSubsidy() public view {
        // Explicit regression: copying a production curve does not guarantee
        // borrower interest covers supplier interest at every utilization.
        uint256 utilization = 1e17;
        assertGt(comet.getSupplyRate(utilization), uint256(comet.getBorrowRate(utilization)) * utilization / 1e18);
    }

    function testFuzzRatesMatchSnapshotFormula(uint256 utilization) public view {
        utilization = bound(utilization, 0, 1e18);
        uint256 kink = referenceValue("supplyKink");
        uint256 lowUse = utilization > kink ? kink : utilization;
        uint256 highUse = utilization > kink ? utilization - kink : 0;
        uint256 supply = referenceValue("supplyPerSecondInterestRateBase")
            + referenceValue("supplyPerSecondInterestRateSlopeLow") * lowUse / 1e18
            + referenceValue("supplyPerSecondInterestRateSlopeHigh") * highUse / 1e18;
        uint256 borrowRate = referenceValue("borrowPerSecondInterestRateBase")
            + referenceValue("borrowPerSecondInterestRateSlopeLow") * lowUse / 1e18
            + referenceValue("borrowPerSecondInterestRateSlopeHigh") * highUse / 1e18;
        assertEq(comet.getSupplyRate(utilization), supply);
        assertEq(comet.getBorrowRate(utilization), borrowRate);
    }
}
