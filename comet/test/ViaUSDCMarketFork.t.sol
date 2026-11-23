// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.15;

import {Test} from "forge-std/Test.sol";
import {LithiumComet} from "../src/LithiumComet.sol";

interface IBridgedUSDC {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract ViaUSDCMarketForkTest is Test {
    address constant BASE = 0x97b56A20498a5B8E4F5d9ba46D24327A0826E3b7;
    address constant LEGACY = 0x9AAF693E76547ab9423D680890F5c8432C4c9619;
    address constant LEGACY_TOKEN = 0xc4361F046d767615ea70b8C65f7740CEB775Bbed;
    address constant MARKET = 0x3e05d1d899625A92c4F177214BD6c25f653f4d93;

    function testSupplyAndBorrowViaUSDCOnFork() external {
        if (!vm.envOr("RUN_VIA_USDC_FORK", false)) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(vm.envOr("VIA_USDC_FORK_RPC", string("https://rpc.testnet.liteforge.zeeve.net/")));
        vm.setEvmVersion("prague");
        assertEq(block.chainid, 4441);
        LithiumComet oldMarket = LithiumComet(payable(LEGACY));
        uint256 oldSupply = oldMarket.totalSupply();
        uint256 oldDebt = oldMarket.totalBorrow();
        LithiumComet market = LithiumComet(payable(MARKET));
        assertEq(market.baseToken(), BASE);
        assertEq(market.getAssetInfo(0).asset, address(0));

        IBridgedUSDC token = IBridgedUSDC(BASE);
        uint256 deposit = 2_000_000;
        address lender = makeAddr("lender");
        deal(BASE, lender, deposit);
        uint256 initialCash = token.balanceOf(MARKET);
        address borrower = makeAddr("borrower");
        vm.startPrank(lender);
        assertTrue(token.approve(address(market), deposit));
        market.supply(BASE, deposit);
        vm.stopPrank();
        assertEq(token.balanceOf(MARKET), initialCash + deposit);
        assertApproxEqAbs(market.balanceOf(lender), deposit, 1);

        vm.deal(borrower, 1 ether);
        vm.startPrank(borrower);
        market.supplyNative{value: 1 ether}();
        market.withdraw(BASE, 1_000_000);
        assertEq(token.balanceOf(borrower), 1_000_000);
        assertGt(market.borrowBalanceOf(borrower), 0);
        assertTrue(token.approve(address(market), 1_000_000));
        market.supply(BASE, 1_000_000);
        assertEq(market.borrowBalanceOf(borrower), 0);
        market.withdraw(address(0), 1 ether);
        vm.stopPrank();

        vm.startPrank(lender);
        market.withdraw(BASE, type(uint256).max);
        vm.expectRevert();
        market.supply(LEGACY_TOKEN, 1);
        vm.stopPrank();
        assertApproxEqAbs(token.balanceOf(lender), deposit, 1);
        assertEq(oldMarket.baseToken(), LEGACY_TOKEN);
        assertEq(oldMarket.totalSupply(), oldSupply);
        assertEq(oldMarket.totalBorrow(), oldDebt);
    }
}
