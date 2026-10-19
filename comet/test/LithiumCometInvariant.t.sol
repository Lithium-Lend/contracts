// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.15;

import {Test} from "forge-std/Test.sol";
import {LithiumCometFixture, ForceNative, MockUSDC} from "./LithiumComet.t.sol";
import {LithiumComet} from "../src/LithiumComet.sol";
import {CometExtInterface} from "comet/CometExtInterface.sol";

contract NativeCashHandler is Test {
    LithiumComet public immutable comet;
    MockUSDC public immutable usdc;
    uint256 public forced;

    constructor(LithiumComet comet_, MockUSDC usdc_) {
        comet = comet_;
        usdc = usdc_;
        usdc.approve(address(comet), type(uint256).max);
    }

    function deposit(uint96 seed) external {
        uint256 used = CometExtInterface(address(comet)).collateralBalanceOf(address(this), address(0));
        if (used == 1000 ether) return;
        uint256 amount = bound(uint256(seed), 1, 1000 ether - used);
        vm.deal(address(this), address(this).balance + amount);
        comet.supplyNative{value: amount}();
    }

    function withdraw(uint96 seed) external {
        uint256 used = CometExtInterface(address(comet)).collateralBalanceOf(address(this), address(0));
        if (used == 0) return;
        comet.withdraw(address(0), bound(uint256(seed), 1, used));
    }

    function force(uint96 seed) external {
        uint256 amount = bound(uint256(seed), 0, 1000 ether);
        vm.deal(address(this), address(this).balance + amount);
        new ForceNative{value: amount}(payable(address(comet)));
        forced += amount;
    }

    function supplyBase(uint64 seed) external {
        // Bound each fuzz action, not the market's aggregate supply.
        uint256 amount = bound(uint256(seed), 1, 1_000_000e6);
        usdc.mint(address(this), amount);
        comet.supply(address(usdc), amount);
    }

    function withdrawBase(uint64 seed) external {
        uint256 supplied = comet.balanceOf(address(this));
        if (supplied == 0) return;
        comet.withdraw(address(usdc), bound(uint256(seed), 1, supplied));
    }
    receive() external payable {}
}

contract LithiumCometInvariantTest is LithiumCometFixture {
    NativeCashHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new NativeCashHandler(comet, usdc);
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = handler.deposit.selector;
        selectors[1] = handler.withdraw.selector;
        selectors[2] = handler.force.selector;
        selectors[3] = handler.supplyBase.selector;
        selectors[4] = handler.withdrawBase.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariantNativeConservation() public view {
        assertEq(comet.accountedNative(), ext.collateralBalanceOf(address(handler), address(0)));
        assertEq(address(comet).balance, comet.accountedNative() + handler.forced());
        assertEq(comet.excessNative(), handler.forced());
        assertEq(comet.getCollateralReserves(address(0)), 0);
    }

    function invariantNoDebtFromDepositsOrForcedValue() public view {
        assertEq(comet.totalBorrow(), 0);
        assertEq(comet.borrowBalanceOf(address(handler)), 0);
        // This handler does not advance time, donate base assets, or borrow.
        assertEq(comet.totalSupply(), usdc.balanceOf(address(comet)));
        assertEq(comet.totalSupply(), comet.balanceOf(address(this)) + comet.balanceOf(address(handler)));
        assertLe(comet.accountedNative(), comet.getAssetInfo(0).supplyCap);
    }
}
