// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.15;

import {Test} from "forge-std/Test.sol";
import {NativeBaseFixture} from "./LithiumNativeBaseComet.t.sol";
import {AdditionalMarketToken} from "./AdditionalMarketMocks.sol";
import {MockFeed, ForceNative} from "./LithiumComet.t.sol";
import {LithiumNativeBaseComet} from "../src/LithiumNativeBaseComet.sol";
import {CometExtInterface} from "comet/CometExtInterface.sol";

contract NativeBaseHandler is Test {
    LithiumNativeBaseComet public immutable market;
    AdditionalMarketToken public immutable token;
    MockFeed internal immutable ltc;
    MockFeed internal immutable usd;
    address public constant BORROWER = address(0xDEB7);
    uint256 public forced;
    uint256 public donatedCollateral;

    constructor(LithiumNativeBaseComet market_, AdditionalMarketToken token_, MockFeed ltc_, MockFeed usd_) {
        market = market_;
        token = token_;
        ltc = ltc_;
        usd = usd_;
        vm.prank(BORROWER);
        token.approve(address(market), type(uint256).max);
    }

    function deposit(uint96 seed) external {
        uint256 amount = bound(uint256(seed), 1, 100 ether);
        vm.deal(address(this), address(this).balance + amount);
        market.supplyNative{value: amount}();
    }

    function withdraw(uint96 seed) external {
        uint256 available = market.balanceOf(address(this));
        if (available > market.accountedNative()) available = market.accountedNative();
        if (available == 0) return;
        market.withdraw(address(0), bound(uint256(seed), 1, available));
    }

    function supplyCollateral(uint64 seed) external {
        uint256 used = CometExtInterface(address(market)).collateralBalanceOf(BORROWER, address(token));
        if (used >= 1_000_000e6) return;
        uint256 amount = bound(uint256(seed), 1, 1_000_000e6 - used);
        token.mint(BORROWER, amount);
        vm.prank(BORROWER);
        market.supply(address(token), amount);
    }

    function borrow(uint96 seed) external {
        uint256 collateral = CometExtInterface(address(market)).collateralBalanceOf(BORROWER, address(token));
        uint256 capacity = collateral * 1e12 / 250; // 40% LTV at $100 per zkLTC.
        uint256 debt = market.borrowBalanceOf(BORROWER);
        if (debt >= capacity) return;
        uint256 available = capacity - debt;
        if (available > market.accountedNative()) available = market.accountedNative();
        // Absorption can leave a positive base balance. Consume that balance
        // before opening at least the minimum debt, avoiding an invalid dust borrow.
        uint256 minimum = market.balanceOf(BORROWER) + market.baseBorrowMin();
        if (available < minimum) return;
        vm.prank(BORROWER);
        market.withdraw(address(0), bound(uint256(seed), minimum, available));
    }

    function repay(uint96 seed) external {
        uint256 debt = market.borrowBalanceOf(BORROWER);
        if (debt == 0) return;
        uint256 amount = bound(uint256(seed), 1, debt);
        vm.deal(address(this), address(this).balance + amount);
        market.supplyNativeTo{value: amount}(BORROWER);
    }

    function donate(uint96 seed, uint64 collateralSeed) external {
        uint256 amount = bound(uint256(seed), 0, 100 ether);
        vm.deal(address(this), address(this).balance + amount);
        new ForceNative{value: amount}(payable(address(market)));
        forced += amount;
        uint256 collateral = bound(uint256(collateralSeed), 0, 100_000e6);
        token.mint(address(market), collateral);
        donatedCollateral += collateral;
    }

    function advance(uint32 seed) external {
        vm.warp(block.timestamp + bound(uint256(seed), 1, 1 days));
        ltc.set(100e8);
        usd.set(1e8);
        market.accrueAccount(BORROWER);
    }

    function absorb() external {
        ltc.set(1000e8);
        if (market.isLiquidatable(BORROWER)) {
            address[] memory accounts = new address[](1);
            accounts[0] = BORROWER;
            market.absorb(address(this), accounts);
        }
        ltc.set(100e8);
    }

    function buy() external {
        uint256 payment = 0.001 ether;
        if (market.getReserves() >= int256(market.targetReserves())) return;
        uint256 quote = market.quoteCollateral(address(token), payment);
        if (market.getCollateralReserves(address(token)) < quote) return;
        vm.deal(address(this), address(this).balance + payment);
        market.buyCollateralNative{value: payment}(address(token), quote, address(this));
    }

    receive() external payable {}
}

contract LithiumNativeBaseInvariantTest is NativeBaseFixture {
    NativeBaseHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new NativeBaseHandler(market, usdc, ltcSource, usdSource);
        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = handler.deposit.selector;
        selectors[1] = handler.withdraw.selector;
        selectors[2] = handler.supplyCollateral.selector;
        selectors[3] = handler.borrow.selector;
        selectors[4] = handler.repay.selector;
        selectors[5] = handler.donate.selector;
        selectors[6] = handler.advance.selector;
        selectors[7] = handler.absorb.selector;
        selectors[8] = handler.buy.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariantNativeCashAndForcedValueConserved() public view {
        assertEq(address(market).balance, market.accountedNative() + handler.forced());
        assertEq(market.excessNative(), handler.forced());
        assertEq(
            market.getReserves(),
            int256(market.accountedNative()) + int256(market.totalBorrow()) - int256(market.totalSupply())
        );
    }

    function invariantCollateralCashAndSaleInventoryConserved() public view {
        uint256 userCollateral = ext.collateralBalanceOf(handler.BORROWER(), address(usdc));
        assertEq(market.accountedCollateral(), userCollateral + market.getCollateralReserves(address(usdc)));
        assertEq(usdc.balanceOf(address(market)), market.accountedCollateral() + handler.donatedCollateral());
        assertLe(userCollateral, market.getAssetInfo(0).supplyCap);
    }

    function invariantNoUnownedPrincipal() public view {
        uint256 supplies =
            market.balanceOf(address(this)) + market.balanceOf(address(handler)) + market.balanceOf(handler.BORROWER());
        // Aggregate index multiplication rounds once, individual balances round per account.
        assertApproxEqAbs(market.totalSupply(), supplies, 2);
        assertEq(market.totalBorrow(), market.borrowBalanceOf(handler.BORROWER()));
        assertEq(market.borrowBalanceOf(address(this)), 0);
        assertEq(market.borrowBalanceOf(address(handler)), 0);
    }
}
