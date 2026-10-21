// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.15;

import {RateRecalibrationFixture} from "./RateRecalibration.t.sol";
import {LithiumComet} from "../src/LithiumComet.sol";
import {CometExtInterface} from "comet/CometExtInterface.sol";
import {TransparentUpgradeableProxy} from "comet/vendor/proxy/transparent/TransparentUpgradeableProxy.sol";

/// @dev Selected 3.6% borrowing base. Interest coverage is required across
/// utilization levels, allowing bounded rounding dust, not liquidation losses.
contract LiteForgeRateUpdateTest is RateRecalibrationFixture {
    uint256 internal selected;
    LithiumComet internal original;

    function setUp() public override {
        super.setUp();
        selected = vm.parseJsonUint(candidates, ".preferredCandidateIndex");
        original = newMarket(0);
        comet = newMarket(selected);
    }

    function spread(LithiumComet market, uint256 u) internal view returns (int256) {
        return int256(uint256(market.getBorrowRate(u)) * u / SCALE) - int256(uint256(market.getSupplyRate(u)));
    }

    function repayAll(LithiumComet market) internal {
        vm.startPrank(alice);
        usdc.approve(address(market), type(uint256).max);
        market.supply(address(usdc), type(uint256).max);
        vm.stopPrank();
        assertEq(market.borrowBalanceOf(alice), 0);
    }

    function testSelectedConfigurationChangesOnlyBorrowBase() public view {
        string memory approved = vm.readFile("config/liteforge.rate-update.json");
        string[] memory keys = vm.parseJsonKeys(baseline, ".environment");
        assertEq(vm.parseJsonKeys(approved, ".environment").length, keys.length);
        uint256 changed;
        for (uint256 i; i < keys.length; i++) {
            string memory path = string.concat(".environment.", keys[i]);
            string memory beforeValue = vm.parseJsonString(baseline, path);
            string memory afterValue = vm.parseJsonString(approved, path);
            if (keccak256(bytes(beforeValue)) != keccak256(bytes(afterValue))) {
                changed++;
                assertEq(keys[i], "COMET_BORROW_RATE_BASE");
                assertEq(afterValue, "36000000000000000");
            }
            string memory overridePath = string.concat(".candidates[", vm.toString(selected), "].overrides.", keys[i]);
            string memory expected =
                vm.keyExistsJson(candidates, overridePath) ? vm.parseJsonString(candidates, overridePath) : beforeValue;
            assertEq(afterValue, expected);
        }
        assertEq(changed, 1);
        assertEq(comet.borrowPerSecondInterestRateBase(), uint256(36e15) / 365 days);
        assertEq(comet.getAssetInfo(0).supplyCap, 10 ether);
        assertEq(comet.targetReserves(), 10e6);
        assertEq(comet.getReserves(), 0, "A reserve target does not fund reserves");
    }

    function testFuzzSupplyCurveUnchangedAndBorrowIncreaseIsConstant(uint256 u) public view {
        u = bound(u, 0, 10e18);
        assertEq(comet.getSupplyRate(u), original.getSupplyRate(u));
        uint256 increase = comet.borrowPerSecondInterestRateBase() - original.borrowPerSecondInterestRateBase();
        assertEq(uint256(comet.getBorrowRate(u)) - original.getBorrowRate(u), increase);
        assertApproxEqAbs(increase * 365 days, 21e15, 365 days);
    }

    function testFreshConfigurationOnlyChangesApprovedAssetCapsAndBorrowBase() public view {
        string memory fresh = vm.readFile("config/liteforge.lith-usdc.json");
        string[] memory keys = vm.parseJsonKeys(baseline, ".environment");
        // Remove two custom cap keys and add three explicit administrator keys.
        assertEq(vm.parseJsonKeys(fresh, ".environment").length, keys.length + 1);
        for (uint256 i; i < keys.length; i++) {
            string memory path = string.concat(".environment.", keys[i]);
            bytes32 key = keccak256(bytes(keys[i]));
            if (key == keccak256("COMET_USDC_SUPPLY_CAP") || key == keccak256("COMET_USDC_BORROW_CAP")) {
                assertFalse(vm.keyExistsJson(fresh, path));
            } else if (key == keccak256("COMET_USDC_ADDRESS")) {
                assertTrue(vm.parseJsonAddress(fresh, path) != vm.parseJsonAddress(baseline, path));
            } else if (key == keccak256("COMET_BORROW_RATE_BASE")) {
                assertEq(vm.parseJsonString(fresh, path), "36000000000000000");
            } else {
                assertEq(vm.parseJsonString(fresh, path), vm.parseJsonString(baseline, path));
            }
        }
        address owner = vm.parseJsonAddress(fresh, ".deployer");
        assertEq(vm.parseJsonAddress(fresh, ".environment.COMET_GOVERNOR"), owner);
        assertEq(vm.parseJsonAddress(fresh, ".environment.COMET_PAUSE_GUARDIAN"), owner);
        assertEq(vm.parseJsonAddress(fresh, ".environment.COMET_UPGRADE_OWNER"), owner);
    }

    function testInterestCoverageAtZeroTinyUtilizationAndKinkNeighborhoods() public view {
        assertEq(spread(comet, 0), 0);
        uint256[10] memory points = [uint256(1), 1e5, 1e17, 5e17, 9e17 - 1, 9e17, 9e17 + 1, 1e18, 2e18, 10e18];
        for (uint256 i; i < points.length; i++) {
            assertGe(spread(comet, points[i]), -2);
            assertEq(comet.getSupplyRate(points[i]), original.getSupplyRate(points[i]));
        }
    }

    function testFuzzBorrowerInterestCoversSupplierInterest(uint256 u) public view {
        u = bound(u, 0, 10e18);
        int256 selectedSpread = spread(comet, u);
        assertGe(selectedSpread, spread(original, u));
        assertGe(selectedSpread, -2, "Only per-second integer-rounding dust is allowed");
    }

    function testFuzzActualAccrualMatchesIncomeMinusExpense(uint256 supplySeed, uint256 debtSeed, uint256 elapsed)
        public
    {
        uint256 supplied = bound(supplySeed, 1e6, 1000e6);
        uint256 debt = bound(debtSeed, 1e5, supplied < 500e6 ? supplied : 500e6);
        elapsed = bound(elapsed, 1, 5 * 365 days);
        fund(comet, supplied, debt);
        uint256 u = comet.getUtilization();
        int256 expected = int256(debt * uint256(comet.getBorrowRate(u)) * elapsed / SCALE)
            - int256(supplied * uint256(comet.getSupplyRate(u)) * elapsed / SCALE);
        advanceTime(elapsed);
        comet.accrueAccount(address(this));
        assertApproxEqAbs(comet.getReserves(), expected, 2);
        assertGe(comet.getReserves(), -2);
    }

    function testLowUtilizationNoLongerConsumesReserves() public {
        fund(original, 1000e6, 100e6);
        fund(comet, 1000e6, 100e6);
        advanceTime(365 days);
        original.accrueAccount(address(this));
        comet.accrueAccount(address(this));
        assertLt(original.getReserves(), 0);
        assertGt(comet.getReserves(), 0);
        assertGt(comet.getReserves(), original.getReserves());
        assertApproxEqAbs(comet.getReserves(), int256(277_780), 2);
        assertEq(comet.balanceOf(address(this)), original.balanceOf(address(this)));
    }

    function testHalfUtilizationGeneratesPositiveInterestSpread() public {
        fund(comet, 1000e6, 500e6);
        advanceTime(365 days);
        comet.accrueAccount(address(this));
        assertApproxEqAbs(comet.getReserves(), int256(6_944_500), 2);
    }

    function testHighUtilizationAccrualRemainsPositive() public {
        fund(comet, 500e6, 475e6);
        advanceTime(30 days);
        comet.accrueAccount(address(this));
        assertGt(comet.getReserves(), 0);
    }

    function testEmptyAndUnborrowedMarketsCreateNoInterestClaims() public {
        advanceTime(365 days);
        comet.accrueAccount(address(this));
        assertEq(comet.totalSupply(), 0);
        assertEq(comet.totalBorrow(), 0);
        assertEq(comet.getReserves(), 0);
        fund(comet, 1000e6, 0);
        advanceTime(365 days);
        comet.accrueAccount(address(this));
        assertEq(comet.balanceOf(address(this)), 1000e6);
        assertEq(comet.getReserves(), 0);
    }

    function testDailyAccrualGrowsReservesOverOneYearWithoutSubsidyFunding() public {
        fund(comet, 1000e6, 100e6);
        assertEq(comet.getReserves(), 0);
        for (uint256 day; day < 365; day++) {
            int256 beforeReserves = comet.getReserves();
            advanceTime(1 days);
            comet.accrueAccount(address(this));
            assertGe(comet.getReserves(), beforeReserves - 2);
        }
        assertGt(comet.getReserves(), 0);
    }

    function testFullSupplierExitAfterRepaymentNeedsNoInterestSubsidyFunding() public {
        fund(comet, 1000e6, 100e6);
        advanceTime(30 days);
        repayAll(comet);
        assertGt(comet.getReserves(), 0);
        assertGe(usdc.balanceOf(address(comet)), comet.balanceOf(address(this)));
        comet.withdraw(address(usdc), type(uint256).max);
        assertEq(comet.balanceOf(address(this)), 0);
        assertGt(comet.getReserves(), 0);
    }

    function testExplicitReserveFundingSupportsRepaymentAndFullExit() public {
        fund(comet, 1000e6, 100e6);
        uint256 claims = comet.balanceOf(address(this));
        // Fixture funding only, not a recommended production reserve amount.
        usdc.transfer(address(comet), 1e6);
        assertEq(comet.balanceOf(address(this)), claims);
        advanceTime(30 days);
        repayAll(comet);
        comet.withdraw(address(usdc), type(uint256).max);
        assertEq(comet.balanceOf(address(this)), 0);
        assertGt(comet.getReserves(), int256(1e6));
    }

    function testTinyDebtWithFrequentAccrualMatchesReserveIdentity() public {
        fund(comet, 1000e6, 1e5);
        for (uint256 i; i < 1000; i++) {
            advanceTime(1);
            comet.accrueAccount(address(this));
            assertEq(
                comet.getReserves(),
                int256(usdc.balanceOf(address(comet))) + int256(comet.totalBorrow()) - int256(comet.totalSupply())
            );
        }
        assertGe(comet.getReserves(), -2);
    }

    function testUpgradePreservesStateAndAppliesNewRateOnlyAfterAccrual() public {
        LithiumComet control = newMarket(0);
        fund(original, 1000e6, 100e6);
        fund(control, 1000e6, 100e6);
        vm.prank(alice);
        CometExtInterface(address(original)).allow(bob, true);
        advanceTime(30 days);
        original.accrueAccount(address(this));
        control.accrueAccount(address(this));
        uint256 suppliedBefore = original.balanceOf(address(this));
        uint256 debtBefore = original.borrowBalanceOf(alice);
        int256 reservesBefore = original.getReserves();
        bytes32[21] memory slots;
        for (uint256 i; i < slots.length; i++) {
            slots[i] = vm.load(address(original), bytes32(i));
        }
        newMarket(selected);
        address replacement = deployCode("LithiumComet.sol:LithiumComet", abi.encode(config));
        // Same contract type, storage declarations and compiler settings.
        // Rate parameters are constructor immutables, not added storage fields.
        vm.prank(proxyAdmin);
        TransparentUpgradeableProxy(payable(address(original))).upgradeTo(replacement);
        for (uint256 i; i < slots.length; i++) {
            assertEq(vm.load(address(original), bytes32(i)), slots[i]);
        }
        assertEq(original.balanceOf(address(this)), suppliedBefore);
        assertEq(original.borrowBalanceOf(alice), debtBefore);
        assertEq(original.getReserves(), reservesBefore);
        assertEq(original.accountedNative(), 10 ether);
        assertEq(CometExtInterface(address(original)).collateralBalanceOf(alice, address(0)), 10 ether);
        assertTrue(CometExtInterface(address(original)).isAllowed(alice, bob));
        assertEq(original.borrowPerSecondInterestRateBase(), uint256(36e15) / 365 days);
        uint256 u = original.getUtilization();
        uint256 expectedDebt = debtBefore + debtBefore * uint256(original.getBorrowRate(u)) * 30 days / SCALE;
        advanceTime(30 days);
        original.accrueAccount(address(this));
        control.accrueAccount(address(this));
        assertApproxEqAbs(original.borrowBalanceOf(alice), expectedDebt, 2);
        assertEq(original.balanceOf(address(this)), control.balanceOf(address(this)));
        assertGt(original.getReserves(), control.getReserves());
        assertGt(original.getReserves(), reservesBefore, "New interest must improve reserves");
        assertLt(original.getReserves(), 0, "A rate change does not erase the pre-upgrade deficit");
    }
}
