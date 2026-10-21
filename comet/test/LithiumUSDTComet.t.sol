// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.15;

import {NativeBaseFixture} from "./LithiumNativeBaseComet.t.sol";
import {AdditionalMarketToken} from "./AdditionalMarketMocks.sol";
import {LithiumUSDTComet} from "../src/LithiumUSDTComet.sol";
import {LithiumComet} from "../src/LithiumComet.sol";
import {CometConfiguration} from "comet/CometConfiguration.sol";
import {CometMainInterface} from "comet/CometMainInterface.sol";
import {CometExt} from "comet/CometExt.sol";
import {TransparentUpgradeableProxy} from "comet/vendor/proxy/transparent/TransparentUpgradeableProxy.sol";

contract LithiumUSDTCometTest is NativeBaseFixture {
    LithiumUSDTComet internal usdtMarket;
    AdditionalMarketToken internal usdt;

    function setUp() public override {
        super.setUp();
        usdt = new AdditionalMarketToken(6);
        CometConfiguration.Configuration memory c = config;
        c.baseToken = address(usdt);
        c.baseTokenPriceFeed = config.assetConfigs[0].priceFeed;
        c.baseMinForRewards = 1e6;
        c.baseBorrowMin = 1e6;
        c.targetReserves = 100e6;
        c.extensionDelegate =
            address(new CometExt(CometConfiguration.ExtConfiguration(bytes32("Lithium USDT"), bytes32("liUSDT"))));
        c.assetConfigs[0] =
            CometConfiguration.AssetConfig(address(0), config.baseTokenPriceFeed, 18, 6e17, 7e17, 9e17, 1000 ether);
        address implementation = deployCode("LithiumUSDTComet.sol:LithiumUSDTComet", abi.encode(c));
        usdtMarket = LithiumUSDTComet(
            payable(address(
                    new TransparentUpgradeableProxy(
                        implementation, proxyAdmin, abi.encodeWithSignature("initializeStorage()")
                    )
                ))
        );
        usdt.mint(address(this), 100_000e6);
        usdt.approve(address(usdtMarket), type(uint256).max);
        usdt.mint(alice, 1000e6);
        vm.prank(alice);
        usdt.approve(address(usdtMarket), type(uint256).max);
        // Transfers return no data, as on the nonstandard USDT interface.
        usdt.configure(true, false, false, false);
        usdtMarket.supply(address(usdt), 100_000e6);
        usdt.mint(address(usdtMarket), 100e6);
    }

    function testNoReturnTokenSupplyBorrowRepayAndWithdraw() public {
        vm.startPrank(alice);
        usdtMarket.supplyNative{value: 10 ether}();
        usdtMarket.withdraw(address(usdt), 500e6);
        assertEq(usdt.balanceOf(alice), 1500e6);
        assertEq(usdtMarket.borrowBalanceOf(alice), 500e6);
        usdtMarket.supply(address(usdt), type(uint256).max);
        assertEq(usdtMarket.borrowBalanceOf(alice), 0);
        usdtMarket.withdraw(address(0), 10 ether);
        vm.stopPrank();
        usdtMarket.withdraw(address(usdt), type(uint256).max);
        assertEq(usdtMarket.totalSupply(), 0);
        assertEq(usdtMarket.getReserves(), 100e6);
        assertEq(usdtMarket.accountedNative(), 0);
    }

    function testNativeAndStablecoinMarketsKeepIndependentPositions() public {
        collateral(1000e6);
        borrow(5 ether);
        vm.startPrank(alice);
        usdtMarket.supplyNative{value: 10 ether}();
        usdtMarket.withdraw(address(usdt), 500e6);
        vm.stopPrank();
        assertEq(market.borrowBalanceOf(alice), 5 ether);
        assertEq(usdtMarket.borrowBalanceOf(alice), 500e6);
        assertEq(market.accountedNative(), 105 ether);
        assertEq(usdtMarket.accountedNative(), 10 ether);
        assertEq(usdt.allowance(alice, address(market)), 0);
        assertEq(usdc.allowance(alice, address(usdtMarket)), 0);
        vm.prank(alice);
        usdtMarket.supply(address(usdt), 500e6);
        assertEq(market.borrowBalanceOf(alice), 5 ether);
        assertEq(usdtMarket.borrowBalanceOf(alice), 0);
    }

    function testNoReturnLiquidationAndNativeCollateralSale() public {
        vm.startPrank(alice);
        usdtMarket.supplyNative{value: 10 ether}();
        usdtMarket.withdraw(address(usdt), 500e6);
        vm.stopPrank();
        ltcSource.set(60e8);
        address[] memory accounts = new address[](1);
        accounts[0] = alice;
        usdtMarket.absorb(bob, accounts);
        assertEq(usdtMarket.borrowBalanceOf(alice), 0);
        assertEq(usdtMarket.balanceOf(alice), 40e6);
        assertEq(usdtMarket.getCollateralReserves(address(0)), 10 ether);
        usdt.mint(address(this), 100e6);
        uint256 quote = usdtMarket.quoteCollateral(address(0), 100e6);
        uint256 cashBefore = bob.balance;
        usdtMarket.buyCollateral(address(0), quote, 100e6, bob);
        assertEq(bob.balance, cashBefore + quote);
        assertEq(usdtMarket.getCollateralReserves(address(0)), 10 ether - quote);
    }

    function testRejectedAndTaxedTransfersDoNotMintClaims() public {
        usdt.mint(address(this), 100e6);
        usdt.configure(false, true, false, false);
        vm.expectRevert(CometMainInterface.TransferInFailed.selector);
        usdtMarket.supply(address(usdt), 100e6);
        usdt.configure(false, false, true, false);
        vm.expectRevert(CometMainInterface.TransferInFailed.selector);
        usdtMarket.supply(address(usdt), 100e6);
        usdt.configure(false, false, false, true);
        vm.expectRevert("Token paused");
        usdtMarket.withdraw(address(usdt), 100e6);
        assertEq(usdtMarket.balanceOf(address(this)), 100_000e6);
        assertEq(usdt.balanceOf(address(usdtMarket)), 100_100e6);
    }

    function testZeroResetApprovalWithNoReturnData() public {
        vm.startPrank(bob);
        (bool ok, bytes memory result) =
            address(usdt).call(abi.encodeWithSignature("approve(address,uint256)", address(usdtMarket), 100e6));
        assertTrue(ok);
        assertEq(result.length, 0);
        (ok,) = address(usdt).call(abi.encodeWithSignature("approve(address,uint256)", address(usdtMarket), 200e6));
        assertFalse(ok);
        (ok,) = address(usdt).call(abi.encodeWithSignature("approve(address,uint256)", address(usdtMarket), 0));
        assertTrue(ok);
        (ok,) = address(usdt).call(abi.encodeWithSignature("approve(address,uint256)", address(usdtMarket), 200e6));
        assertTrue(ok);
        vm.stopPrank();
        assertEq(usdt.allowance(bob, address(usdtMarket)), 200e6);
    }

    function testRequiresSixDecimalBaseAndSingleNativeCollateral() public {
        CometConfiguration.Configuration memory c = config;
        c.baseToken = address(new AdditionalMarketToken(18));
        c.assetConfigs[0].asset = address(0);
        vm.expectRevert(CometMainInterface.BadDecimals.selector);
        new LithiumUSDTComet(c);
        c.baseToken = address(usdt);
        c.assetConfigs[0].asset = address(usdc);
        vm.expectRevert(LithiumComet.InvalidConfiguration.selector);
        new LithiumUSDTComet(c);
    }
}
