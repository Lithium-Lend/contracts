// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.38;

import {Test, console2} from "forge-std/Test.sol";
import {NativeLendingFeeVault} from "../src/NativeLendingFeeVault.sol";
import {INativeFeeMarket} from "../src/interfaces/INativeFeeMarket.sol";

/// @dev Run with --fork-url pointing to LiteForge. Only the depositor receives synthetic native funds.
contract NativeFeeStrategyForkTest is Test {
    INativeFeeMarket internal constant MARKET = INativeFeeMarket(0x2CF2179ff3732bd681eA59b339abF86a57922d3F);
    address internal depositor = makeAddr("depositor");
    address internal feeRecipient = makeAddr("feeRecipient");

    function setUp() public {
        vm.skip(block.chainid != 4441);
        assertEq(MARKET.baseToken(), address(0));
        assertEq(MARKET.baseScale(), 1 ether);
    }

    function testOneNative() public {
        compare(1 ether);
    }

    function testTenNative() public {
        compare(10 ether);
    }

    function testHundredNative() public {
        compare(100 ether);
    }

    function testPublishedVaultDepositAndRedeem() public {
        NativeLendingFeeVault vault = NativeLendingFeeVault(payable(0x55eD1A3f1f43C93AC32fEa6f65450a84c209425d));
        assertEq(address(vault.market()), address(MARKET));
        assertEq(vault.depositCap(), 10_000 ether);
        uint256 assets = 1 ether;
        vm.deal(depositor, assets);
        uint256 quote = vault.previewDeposit(assets);
        vm.startPrank(depositor);
        uint256 shares = vault.depositWithMinShares{value: assets}(assets, depositor, quote, block.timestamp);
        assertEq(vault.balanceOf(depositor), shares);
        uint256 redeemable = vault.maxRedeem(depositor);
        assertGt(redeemable, 0);
        uint256 payout = vault.previewRedeem(redeemable);
        assertGt(payout, 0);
        assertEq(vault.redeemWithMinAssets(redeemable, depositor, depositor, payout, block.timestamp), payout);
        assertEq(depositor.balance, payout);
        vm.stopPrank();
    }

    function compare(uint256 assets) internal {
        vm.deal(depositor, assets);
        uint256 snapshot = vm.snapshotState();
        uint256 entryTime = block.timestamp;
        vm.prank(depositor);
        MARKET.supplyNative{value: assets}();
        uint64 directRate = MARKET.getSupplyRate(MARKET.getUtilization());
        vm.warp(entryTime + 7 days);
        uint256 directClaim = MARKET.balanceOf(depositor);
        assertTrue(vm.revertToState(snapshot));

        NativeLendingFeeVault vault = new NativeLendingFeeVault(
            address(MARKET), address(this), feeRecipient, assets, "Native Lending Shares", "nlLTC"
        );
        uint256 preview = vault.previewDeposit(assets);
        vm.prank(depositor);
        (uint256 shares, uint64 entryRate) =
            vault.depositWithMinSupplyRate{value: assets}(assets, depositor, preview, directRate, block.timestamp);
        assertEq(shares, preview);
        assertEq(entryRate, directRate);
        assertEq(MARKET.borrowBalanceOf(address(vault)), 0);

        vm.warp(entryTime + 7 days);
        vault.accrueFees();
        assertEq(vault.totalAssets(), directClaim);
        uint256 netClaim = vault.previewRedeem(shares);
        assertLe(netClaim, directClaim);
        uint256 liquidShares = vault.maxRedeem(depositor);
        assertGt(liquidShares, 0);
        uint256 payout = vault.previewRedeem(liquidShares);
        uint256 balanceBefore = depositor.balance;
        vm.prank(depositor);
        assertEq(vault.redeemWithMinAssets(liquidShares, depositor, depositor, payout, block.timestamp), payout);
        assertEq(depositor.balance - balanceBefore, payout);
        console2.log("Fork block", block.number);
        console2.log("Deposit (wei zkLTC)", assets);
        console2.log("Entry gross APR (1e18 = 100%)", uint256(entryRate) * 365 days);
        console2.log("Direct claim after seven simulated days (wei)", directClaim);
        console2.log("Vault net claim after seven simulated days (wei)", netClaim);
        console2.log("Cash actually redeemed (wei)", payout);
    }
}
