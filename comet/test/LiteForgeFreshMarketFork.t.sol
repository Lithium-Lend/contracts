// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.15;

import {Test} from "forge-std/Test.sol";
import {LithiumComet} from "../src/LithiumComet.sol";
import {CometExtInterface} from "comet/CometExtInterface.sol";
import {ILithiumUSDC} from "./LithiumUSDCIntegration.t.sol";

/// @dev Tests the actual deployed proxy and token on a local pinned fork.
/// No live claims, lending actions, or administrative transactions are broadcast.
contract LiteForgeFreshMarketForkTest is Test {
    LithiumComet internal comet;
    ILithiumUSDC internal token;
    address internal lender = address(0xA11CE);
    address internal borrower = address(0xB0B);
    uint256 internal constant CLAIM = 10_000e6;

    function setUp() public {
        if (!vm.envOr("LITHIUM_COMET_FORK", false)) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork("litvm_liteforge", 56212280);
        vm.setEvmVersion("prague");
        assertEq(block.chainid, 4441);
        string memory record = vm.readFile("deployments/liteforge-lith-usdc.json");
        comet = LithiumComet(payable(vm.parseJsonAddress(record, ".comet")));
        token = ILithiumUSDC(vm.parseJsonAddress(record, ".baseToken"));
        assertEq(comet.baseToken(), address(token));
        vm.deal(lender, 20 ether);
        vm.deal(borrower, 20 ether);
    }

    function supplyClaim(address user) internal {
        vm.startPrank(user);
        assertEq(token.faucet(), CLAIM);
        token.approve(address(comet), CLAIM);
        comet.supply(address(token), CLAIM);
        vm.stopPrank();
    }

    function testDeployedMetadataRatesAndEmptyState() public view {
        assertEq(token.name(), "Lithium USDC");
        assertEq(token.symbol(), "lithUSDC");
        assertEq(token.decimals(), 6);
        assertEq(comet.borrowPerSecondInterestRateBase(), uint256(36e15) / 365 days);
        assertEq(comet.supplyPerSecondInterestRateSlopeLow(), uint256(35999999986896000) / 365 days);
        assertEq(comet.getAssetInfo(0).borrowCollateralFactor, 6e17);
        assertEq(comet.getAssetInfo(0).liquidateCollateralFactor, 7e17);
        assertEq(comet.getAssetInfo(0).supplyCap, 10 ether);
        assertEq(comet.totalSupply(), 0);
        assertEq(comet.totalBorrow(), 0);
        assertEq(comet.getReserves(), 0);
    }

    function testDeployedFullClaimSupplyAndWithdrawal() public {
        supplyClaim(lender);
        vm.prank(lender);
        comet.withdraw(address(token), CLAIM);
        assertEq(token.balanceOf(lender), CLAIM);
        assertEq(comet.totalSupply(), 0);
    }

    function testDeployedMultipleFullClaimsSupplyWithoutBaseCap() public {
        supplyClaim(lender);
        supplyClaim(borrower);
        assertEq(comet.totalSupply(), 2 * CLAIM);
        assertEq(token.balanceOf(address(comet)), 2 * CLAIM);
    }

    function testDeployedNativeBorrowRepayAndExit() public {
        supplyClaim(lender);
        vm.startPrank(borrower);
        comet.supplyNative{value: 1 ether}();
        comet.withdraw(address(token), 10e6);
        assertEq(comet.borrowBalanceOf(borrower), 10e6);
        token.approve(address(comet), 10e6);
        comet.supply(address(token), 10e6);
        comet.withdraw(address(0), 1 ether);
        vm.stopPrank();
        assertEq(borrower.balance, 20 ether);
        assertEq(comet.borrowBalanceOf(borrower), 0);
        assertEq(CometExtInterface(address(comet)).collateralBalanceOf(borrower, address(0)), 0);
    }

    function testDeployedCollateralCapRetained() public {
        vm.prank(borrower);
        vm.expectRevert();
        comet.supplyNative{value: 10 ether + 1}();
    }

    function testDeployedUncollateralizedBorrowStillRejected() public {
        supplyClaim(lender);
        vm.prank(borrower);
        vm.expectRevert();
        comet.withdraw(address(token), 1e6);
    }

    function testDeployedFaucetCooldown() public {
        vm.startPrank(lender);
        token.faucet();
        uint256 next = token.nextFaucetAt(lender);
        assertEq(next, block.timestamp + 1 days);
        vm.expectRevert(abi.encodeWithSignature("FaucetCooldownActive(uint256)", next));
        token.faucet();
        vm.warp(next);
        token.faucet();
        vm.stopPrank();
        assertEq(token.balanceOf(lender), 2 * CLAIM);
    }

    function testDeployedProxyCannotReinitialize() public {
        vm.prank(borrower);
        vm.expectRevert();
        comet.initializeStorage();
    }
}
