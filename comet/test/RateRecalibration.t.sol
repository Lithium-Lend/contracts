// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.15;

import {LithiumCometFixture} from "./LithiumComet.t.sol";
import {LithiumComet} from "../src/LithiumComet.sol";
import {CometExtInterface} from "comet/CometExtInterface.sol";
import {TransparentUpgradeableProxy} from "comet/vendor/proxy/transparent/TransparentUpgradeableProxy.sol";

/// @dev Uses the current market logic and approved testnet risk parameters.
abstract contract RateRecalibrationFixture is LithiumCometFixture {
    string internal baseline;
    string internal candidates;
    uint256 internal nonSubsidizedReference;
    uint256 internal constant SCALE = 1e18;

    function advanceTime(uint256 elapsed) internal {
        // Solidity may cache block.timestamp within one test transaction.
        // The cheatcode getter observes each preceding warp in repeated steps.
        uint256 beforeTime = vm.getBlockTimestamp();
        vm.warp(beforeTime + elapsed);
        assertEq(vm.getBlockTimestamp(), beforeTime + elapsed);
    }

    function setUp() public virtual override {
        super.setUp();
        baseline = vm.readFile("config/liteforge.proposed.json");
        candidates = vm.readFile("config/rate-simulation.json");
        nonSubsidizedReference = vm.parseJsonUint(candidates, ".nonSubsidizedReferenceIndex");
        comet = newMarket(nonSubsidizedReference);
    }

    function parameter(uint256 candidate, string memory key) internal view returns (uint256) {
        string memory path = string.concat(".candidates[", vm.toString(candidate), "].overrides.", key);
        if (vm.keyExistsJson(candidates, path)) return vm.parseUint(vm.parseJsonString(candidates, path));
        return vm.parseUint(vm.parseJsonString(baseline, string.concat(".environment.", key)));
    }

    function newMarket(uint256 candidate) internal returns (LithiumComet market) {
        config.supplyKink = uint64(parameter(candidate, "COMET_SUPPLY_KINK"));
        config.borrowKink = uint64(parameter(candidate, "COMET_BORROW_KINK"));
        config.supplyPerYearInterestRateBase = uint64(parameter(candidate, "COMET_SUPPLY_RATE_BASE"));
        config.supplyPerYearInterestRateSlopeLow = uint64(parameter(candidate, "COMET_SUPPLY_SLOPE_LOW"));
        config.supplyPerYearInterestRateSlopeHigh = uint64(parameter(candidate, "COMET_SUPPLY_SLOPE_HIGH"));
        config.borrowPerYearInterestRateBase = uint64(parameter(candidate, "COMET_BORROW_RATE_BASE"));
        config.borrowPerYearInterestRateSlopeLow = uint64(parameter(candidate, "COMET_BORROW_SLOPE_LOW"));
        config.borrowPerYearInterestRateSlopeHigh = uint64(parameter(candidate, "COMET_BORROW_SLOPE_HIGH"));
        config.baseBorrowMin = uint104(parameter(candidate, "COMET_MINIMUM_BORROW"));
        config.targetReserves = uint104(parameter(candidate, "COMET_TARGET_RESERVES"));
        config.storeFrontPriceFactor = uint64(parameter(candidate, "COMET_STOREFRONT_FACTOR"));
        config.assetConfigs[0].borrowCollateralFactor = uint64(parameter(candidate, "COMET_BORROW_COLLATERAL_FACTOR"));
        config.assetConfigs[0].liquidateCollateralFactor =
            uint64(parameter(candidate, "COMET_LIQUIDATION_COLLATERAL_FACTOR"));
        config.assetConfigs[0].liquidationFactor = uint64(parameter(candidate, "COMET_LIQUIDATION_FACTOR"));
        config.assetConfigs[0].supplyCap = uint128(parameter(candidate, "COMET_ZKLTC_SUPPLY_CAP"));
        address impl = deployCode("LithiumComet.sol:LithiumComet", abi.encode(config));
        market = LithiumComet(
            payable(address(
                    new TransparentUpgradeableProxy(impl, proxyAdmin, abi.encodeWithSignature("initializeStorage()"))
                ))
        );
        usdc.approve(address(market), type(uint256).max);
    }

    function fund(LithiumComet market, uint256 supplied, uint256 debt) internal {
        market.supply(address(usdc), supplied);
        if (debt != 0) {
            refresh();
            vm.startPrank(alice);
            market.supplyNative{value: 10 ether}();
            market.withdraw(address(usdc), debt);
            vm.stopPrank();
        }
    }
}

/// @dev Retains strict coverage for the seven non-subsidized alternatives.
/// The selected configuration and upgrade are also tested in LiteForgeRateUpdateTest.
contract RateRecalibrationTest is RateRecalibrationFixture {
    function assertMargin(LithiumComet market, uint256 u, uint256 candidate) internal view {
        uint256 income = uint256(market.getBorrowRate(u)) * u / SCALE;
        uint256 limit = candidate == 1 || candidate == 5 ? income : income * 9 / 10;
        assertLe(market.getSupplyRate(u), limit + 2, "interest margin, including floor tolerance");
    }

    function testBaselineReproducesReserveDrainAfterThirtyDays() public {
        LithiumComet original = newMarket(0);
        fund(original, 1000e6, 500e6);
        assertEq(original.getReserves(), 0);
        advanceTime(30 days);
        original.accrueAccount(address(this));
        assertLt(original.getReserves(), 0);
    }

    function testCandidateMarginsAtZeroKinkAndHighUtilization() public {
        uint256[10] memory points = [uint256(0), 1, 1e17, 5e17, 9e17 - 1, 9e17, 9e17 + 1, 1e18, 2e18, 10e18];
        for (uint256 candidate = 1; candidate <= 7; candidate++) {
            LithiumComet market = newMarket(candidate);
            for (uint256 i; i < points.length; i++) {
                assertMargin(market, points[i], candidate);
            }
        }
    }

    function testFuzzAllCandidateInterestMargins(uint256 candidate, uint256 u) public {
        candidate = bound(candidate, 1, 7);
        u = bound(u, 0, 10e18);
        assertMargin(newMarket(candidate), u, candidate);
    }

    function testFuzzNonSubsidizedReferenceSupplyCurveIsUnchanged(uint256 u) public view {
        u = bound(u, 0, 10e18);
        uint256 k = parameter(0, "COMET_SUPPLY_KINK");
        uint256 lowU = u < k ? u : k;
        uint256 expected = parameter(0, "COMET_SUPPLY_RATE_BASE") / 365 days
            + (parameter(0, "COMET_SUPPLY_SLOPE_LOW") / 365 days) * lowU / SCALE
            + (parameter(0, "COMET_SUPPLY_SLOPE_HIGH") / 365 days) * (u - lowU) / SCALE;
        assertEq(comet.getSupplyRate(u), expected);
    }

    function testEmptyMarketAccruesWithoutCreatingClaims() public {
        advanceTime(365 days);
        comet.accrueAccount(address(this));
        assertEq(comet.totalSupply(), 0);
        assertEq(comet.totalBorrow(), 0);
        assertEq(comet.getReserves(), 0);
    }

    function testSupplyWithoutBorrowingEarnsNoUnfundedInterest() public {
        fund(comet, 1000e6, 0);
        advanceTime(365 days);
        comet.accrueAccount(address(this));
        assertEq(comet.balanceOf(address(this)), 1000e6);
        assertEq(comet.getReserves(), 0);
    }

    function testFuzzActualAccrualAcrossCapsAndLongIdlePeriods(uint256 supplySeed, uint256 debtSeed, uint256 elapsed)
        public
    {
        uint256 supplied = bound(supplySeed, 1e6, 1000e6);
        uint256 maxDebt = supplied < 500e6 ? supplied : 500e6;
        uint256 debt = bound(debtSeed, 1e5, maxDebt);
        elapsed = bound(elapsed, 1, 5 * 365 days);
        fund(comet, supplied, debt);
        advanceTime(elapsed);
        comet.accrueAccount(address(this));
        // Two smallest USDC units accommodate principal/index truncation.
        assertGe(comet.getReserves(), -2);
    }

    function testAllCandidatesActualAccrualAtHighUtilization() public {
        for (uint256 candidate = 1; candidate <= 7; candidate++) {
            LithiumComet market = newMarket(candidate);
            fund(market, 500e6, 475e6);
            advanceTime(30 days);
            market.accrueAccount(address(this));
            assertGt(market.getReserves(), 0);
        }
    }

    function testNonSubsidizedReferenceDailyAccrualForOneYearAtLowUtilization() public {
        fund(comet, 1000e6, 100e6);
        for (uint256 day; day < 365; day++) {
            int256 beforeReserves = comet.getReserves();
            advanceTime(1 days);
            comet.accrueAccount(address(this));
            assertGe(comet.getReserves(), beforeReserves - 2);
        }
        assertGt(comet.getReserves(), 0);
    }

    function testNonSubsidizedReferenceTinyDebtWithFrequentAccrualHasBoundedDust() public {
        fund(comet, 1000e6, 1e5);
        for (uint256 i; i < 1000; i++) {
            int256 beforeReserves = comet.getReserves();
            advanceTime(1);
            comet.accrueAccount(address(this));
            assertGe(comet.getReserves(), beforeReserves - 2);
        }
        assertGe(comet.getReserves(), -2);
    }

    function testNonSubsidizedReferenceRepaymentAndFullSupplierExit() public {
        fund(comet, 1000e6, 500e6);
        advanceTime(30 days);
        vm.startPrank(alice);
        usdc.approve(address(comet), type(uint256).max);
        comet.supply(address(usdc), type(uint256).max);
        vm.stopPrank();
        assertEq(comet.borrowBalanceOf(alice), 0);
        comet.withdraw(address(usdc), type(uint256).max);
        assertEq(comet.balanceOf(address(this)), 0);
        assertGe(comet.getReserves(), -2);
    }

    function testUpgradeSettlesOldInterestBeforeNewParameters() public {
        LithiumComet original = newMarket(0);
        fund(original, 1000e6, 100e6);
        advanceTime(30 days);
        original.accrueAccount(address(this));
        uint256 suppliedBefore = original.balanceOf(address(this));
        uint256 debtBefore = original.borrowBalanceOf(alice);
        int256 reservesBefore = original.getReserves();
        // newMarket sets the candidate configuration without changing old state.
        newMarket(nonSubsidizedReference);
        address replacement = deployCode("LithiumComet.sol:LithiumComet", abi.encode(config));
        vm.prank(proxyAdmin);
        TransparentUpgradeableProxy(payable(address(original))).upgradeTo(replacement);
        assertEq(original.balanceOf(address(this)), suppliedBefore);
        assertEq(original.borrowBalanceOf(alice), debtBefore);
        assertEq(original.getReserves(), reservesBefore);
        assertEq(CometExtInterface(address(original)).collateralBalanceOf(alice, address(0)), 10 ether);
        advanceTime(30 days);
        original.accrueAccount(address(this));
        assertGt(original.getReserves(), reservesBefore);
    }
}
