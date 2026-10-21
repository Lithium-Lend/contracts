// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.15;

import {NativeBaseFixture} from "./LithiumNativeBaseComet.t.sol";
import {AdditionalMarketToken} from "./AdditionalMarketMocks.sol";
import {LithiumNativeBaseComet} from "../src/LithiumNativeBaseComet.sol";
import {LithiumUSDTComet} from "../src/LithiumUSDTComet.sol";
import {CometMainInterface} from "comet/CometMainInterface.sol";
import {CometConfiguration} from "comet/CometConfiguration.sol";
import {TransparentUpgradeableProxy} from "comet/vendor/proxy/transparent/TransparentUpgradeableProxy.sol";

/// @notice Cross-check the independent integer model against both actual market implementations.
/// @dev Large fixture caps isolate accounting. They are not deployment recommendations.
contract AdditionalMarketEconomicsTest is NativeBaseFixture {
    string internal study;
    string internal expected;
    AdditionalMarketToken internal usdt;

    function setUp() public override {
        super.setUp();
        study = vm.readFile("config/additional-market-study.json");
        expected = vm.readFile("config/additional-market-model-fixtures.json");
        usdt = new AdditionalMarketToken(6);
        usdt.mint(address(this), 1_000_000e6);
    }

    function uintAt(string memory json, string memory path) internal pure returns (uint256) {
        return vm.parseJsonUint(json, path);
    }

    function stringUint(string memory json, string memory path) internal pure returns (uint256) {
        return vm.parseUint(vm.parseJsonString(json, path));
    }

    function row(string memory name, uint256 i) internal pure returns (string memory) {
        return string.concat(".", name, "[", vm.toString(i), "]");
    }

    function newMarket(bool native_, uint256 candidate, uint256 pair) internal returns (CometMainInterface m) {
        refresh();
        CometConfiguration.Configuration memory c = config;
        string memory p = row("curves", candidate);
        c.supplyKink = uint64(stringUint(study, string.concat(p, ".kink")));
        c.borrowKink = c.supplyKink;
        c.supplyPerYearInterestRateBase = uint64(stringUint(study, string.concat(p, ".supplyBase")));
        c.supplyPerYearInterestRateSlopeLow = uint64(stringUint(study, string.concat(p, ".supplyLow")));
        c.supplyPerYearInterestRateSlopeHigh = uint64(stringUint(study, string.concat(p, ".supplyHigh")));
        c.borrowPerYearInterestRateBase = uint64(stringUint(study, string.concat(p, ".borrowBase")));
        c.borrowPerYearInterestRateSlopeLow = uint64(stringUint(study, string.concat(p, ".borrowLow")));
        c.borrowPerYearInterestRateSlopeHigh = uint64(stringUint(study, string.concat(p, ".borrowHigh")));
        c.storeFrontPriceFactor = 6e17;
        c.assetConfigs[0].liquidationFactor = 9e17;
        c.assetConfigs[0].borrowCollateralFactor =
            uint64(uintAt(study, string.concat(row("riskPairs", pair), ".borrowBps")) * 1e14);
        c.assetConfigs[0].liquidateCollateralFactor =
            uint64(uintAt(study, string.concat(row("riskPairs", pair), ".liquidateBps")) * 1e14);
        if (!native_) {
            c.baseToken = address(usdt);
            c.baseTokenPriceFeed = config.assetConfigs[0].priceFeed;
            c.baseMinForRewards = 1e6;
            c.baseBorrowMin = 1e5;
            c.targetReserves = 1_000_000e6;
            c.assetConfigs[0].asset = address(0);
            c.assetConfigs[0].priceFeed = config.baseTokenPriceFeed;
            c.assetConfigs[0].decimals = 18;
            c.assetConfigs[0].supplyCap = 10000 ether;
        } else {
            c.baseBorrowMin = 0.001 ether;
            c.targetReserves = 1_000_000 ether;
        }
        address impl = deployCode(
            native_ ? "LithiumNativeBaseComet.sol:LithiumNativeBaseComet" : "LithiumUSDTComet.sol:LithiumUSDTComet",
            abi.encode(c)
        );
        m = CometMainInterface(
            address(new TransparentUpgradeableProxy(impl, proxyAdmin, abi.encodeWithSignature("initializeStorage()")))
        );
        usdt.approve(address(m), type(uint256).max);
        vm.prank(alice);
        usdc.approve(address(m), type(uint256).max);
    }

    function fund(CometMainInterface m, bool native_, uint256 supplied, uint256 debt, uint256 collateral_) internal {
        if (native_) LithiumNativeBaseComet(payable(address(m))).supplyNative{value: supplied}();
        else m.supply(address(usdt), supplied);
        vm.startPrank(alice);
        if (native_) m.supply(address(usdc), collateral_);
        else LithiumUSDTComet(payable(address(m))).supplyNative{value: collateral_}();
        m.withdraw(native_ ? address(0) : address(usdt), debt);
        vm.stopPrank();
    }

    function testOneYearAccrualReferenceCurveMatchesModel() public {
        compareAccrual(0, 12);
    }

    function testOneYearAccrualReserveBufferCurveMatchesModel() public {
        compareAccrual(12, 24);
    }

    function testOneYearAccrualPreservedSupplyCurveMatchesModel() public {
        compareAccrual(24, 36);
    }

    function testOneYearAccrualEarlierKinkCurveMatchesModel() public {
        compareAccrual(36, 48);
    }

    function compareAccrual(uint256 start, uint256 end) internal {
        for (uint256 i = start; i < end; i++) {
            string memory p = row("accrual", i);
            bool native_ = uintAt(expected, string.concat(p, ".decimals")) == 18;
            CometMainInterface m = newMarket(native_, uintAt(expected, string.concat(p, ".curve")), 0);
            uint256 unit = native_ ? 1e18 : 1e6;
            uint256 debt = 1000 * unit * uintAt(expected, string.concat(p, ".utilizationBps")) / 10000;
            fund(m, native_, 1000 * unit, debt, native_ ? 250_000e6 : 25 ether);
            uint256 interval = uintAt(expected, string.concat(p, ".intervalDays"));
            for (uint256 day = interval; day <= 365; day += interval) {
                vm.warp(vm.getBlockTimestamp() + interval * 1 days);
                m.accrueAccount(alice);
            }
            assertEq(m.totalSupply(), stringUint(expected, string.concat(p, ".supply")), p);
            assertEq(m.totalBorrow(), stringUint(expected, string.concat(p, ".debt")), p);
            assertEq(m.getReserves(), int256(stringUint(expected, string.concat(p, ".reserves"))), p);
        }
    }

    function testPriceGapsAbsorptionCreditsAndCollateralSalesMatchModel() public {
        for (uint256 i; i < 18; i++) {
            string memory p = row("liquidation", i);
            bool native_ = vm.parseJsonBool(expected, string.concat(p, ".native"));
            uint256 pair = uintAt(expected, string.concat(p, ".pair"));
            CometMainInterface m = newMarket(native_, 1, pair);
            uint256 ltv = uintAt(study, string.concat(row("riskPairs", pair), ".borrowBps"));
            uint256 debt = (native_ ? 10 ether : 1000e6) * ltv / 10000;
            fund(m, native_, debt, debt, native_ ? 1000e6 : 10 ether);
            vm.warp(vm.getBlockTimestamp() + 7 days);
            uint256 cm = uintAt(expected, string.concat(p, ".collateralBps"));
            uint256 bm = uintAt(expected, string.concat(p, ".baseBps"));
            ltcSource.set(int256(100e8 * (native_ ? bm : cm) / 10000));
            usdSource.set(int256(1e8 * (native_ ? cm : bm) / 10000));
            m.accrueAccount(alice);
            assertEq(m.borrowBalanceOf(alice), stringUint(expected, string.concat(p, ".debt")), p);
            bool eligible = vm.parseJsonBool(expected, string.concat(p, ".liquidatable"));
            assertEq(m.isLiquidatable(alice), eligible, p);
            if (!eligible) continue;
            int256 beforeReserves = m.getReserves();
            address[] memory accounts = new address[](1);
            accounts[0] = alice;
            m.absorb(bob, accounts);
            uint256 tolerance = native_ ? 10000 : 2;
            assertApproxEqAbs(m.balanceOf(alice), stringUint(expected, string.concat(p, ".credit")), tolerance, p);
            assertApproxEqAbs(
                beforeReserves - m.getReserves(),
                int256(stringUint(expected, string.concat(p, ".charge"))),
                tolerance,
                p
            );
            uint256 proceeds = stringUint(expected, string.concat(p, ".proceeds"));
            address asset = native_ ? address(usdc) : address(0);
            uint256 quote = m.quoteCollateral(asset, proceeds);
            assertLe(quote, m.getCollateralReserves(asset));
            if (native_) {
                LithiumNativeBaseComet(payable(address(m))).buyCollateralNative{value: proceeds}(asset, quote, bob);
            } else {
                m.buyCollateral(asset, quote, proceeds, bob);
            }
            int256 expectedDelta = vm.parseInt(vm.parseJsonString(expected, string.concat(p, ".delta")));
            assertApproxEqAbs(m.getReserves() - beforeReserves, expectedDelta, tolerance, p);
        }
    }

    function testNativeWithdrawalRunRevertsAndRecoversAfterRepayment() public {
        CometMainInterface m = newMarket(true, 3, 0);
        fund(m, true, 10 ether, 9 ether, 2000e6);
        assertEq(m.getReserves(), 0);
        m.withdraw(address(0), 1 ether);
        assertEq(LithiumNativeBaseComet(payable(address(m))).accountedNative(), 0);
        vm.expectRevert();
        m.withdraw(address(0), 1 ether);
        vm.prank(alice);
        LithiumNativeBaseComet(payable(address(m))).supplyNative{value: 1 ether}();
        m.withdraw(address(0), 1 ether);
        assertEq(m.getReserves(), 0);
    }
}
