// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.15;

import {Test} from "forge-std/Test.sol";
import {LithiumNativeBaseComet} from "../src/LithiumNativeBaseComet.sol";
import {LithiumErc20AssetList} from "../src/LithiumErc20AssetList.sol";
import {LithiumCometPriceFeed} from "../src/LithiumCometPriceFeed.sol";
import {CometConfiguration} from "comet/CometConfiguration.sol";
import {CometMainInterface} from "comet/CometMainInterface.sol";
import {CometExt} from "comet/CometExt.sol";
import {CometExtInterface} from "comet/CometExtInterface.sol";
import {TransparentUpgradeableProxy} from "comet/vendor/proxy/transparent/TransparentUpgradeableProxy.sol";
import {AdditionalMarketToken} from "./AdditionalMarketMocks.sol";
import {MockFeed, ForceNative} from "./LithiumComet.t.sol";

contract NativeBaseReceiver {
    LithiumNativeBaseComet public immutable market;
    bool public reject;
    bool public reenter;
    bool public callbackSucceeded;
    bytes public callbackResult;

    constructor(LithiumNativeBaseComet market_) {
        market = market_;
    }

    function configure(bool reject_, bool reenter_) external {
        reject = reject_;
        reenter = reenter_;
    }

    receive() external payable {
        require(!reject, "Native rejected");
        if (reenter) {
            (callbackSucceeded, callbackResult) =
                address(market).call(abi.encodeWithSignature("accrueAccount(address)", address(this)));
        }
    }
}

abstract contract NativeBaseFixture is Test {
    LithiumNativeBaseComet internal market;
    CometExtInterface internal ext;
    AdditionalMarketToken internal usdc;
    MockFeed internal ltcSource;
    MockFeed internal usdSource;
    CometConfiguration.Configuration internal config;
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal guardian = address(0xCAFE);
    address internal proxyAdmin = address(0xAD);

    function setUp() public virtual {
        vm.warp(1_800_000_000);
        vm.chainId(4441);
        usdc = new AdditionalMarketToken(6);
        ltcSource = new MockFeed(100e8);
        usdSource = new MockFeed(1e8);
        config.governor = address(this);
        config.pauseGuardian = guardian;
        config.baseToken = address(0);
        config.baseTokenPriceFeed = address(new LithiumCometPriceFeed(address(ltcSource), 1 hours));
        config.extensionDelegate =
            address(new CometExt(CometConfiguration.ExtConfiguration(bytes32("Lithium zkLTC"), bytes32("lizkLTC"))));
        config.supplyKink = 8e17;
        config.borrowKink = 8e17;
        config.supplyPerYearInterestRateSlopeLow = 3e16;
        config.borrowPerYearInterestRateBase = 4e16;
        config.borrowPerYearInterestRateSlopeLow = 4e16;
        config.storeFrontPriceFactor = 1e18;
        config.trackingIndexScale = 1e15;
        config.baseMinForRewards = 1 ether;
        config.baseBorrowMin = 0.01 ether;
        config.targetReserves = 10 ether;
        config.assetConfigs
            .push(
                CometConfiguration.AssetConfig(
                    address(usdc),
                    address(new LithiumCometPriceFeed(address(usdSource), 1 hours)),
                    6,
                    6e17,
                    7e17,
                    9e17,
                    10_000_000e6
                )
            );
        address implementation = deployCode("LithiumNativeBaseComet.sol:LithiumNativeBaseComet", abi.encode(config));
        market = LithiumNativeBaseComet(
            payable(address(
                    new TransparentUpgradeableProxy(
                        implementation, proxyAdmin, abi.encodeWithSignature("initializeStorage()")
                    )
                ))
        );
        ext = CometExtInterface(address(market));
        vm.deal(address(this), 100_000 ether);
        vm.deal(alice, 1000 ether);
        vm.deal(bob, 1000 ether);
        market.supplyNative{value: 100 ether}();
        market.fundReservesNative{value: 10 ether}();
        usdc.mint(alice, 20_000_000e6);
        vm.prank(alice);
        usdc.approve(address(market), type(uint256).max);
    }

    function collateral(uint256 amount) internal {
        vm.prank(alice);
        market.supply(address(usdc), amount);
    }

    function borrow(uint256 amount) internal {
        vm.prank(alice);
        market.withdraw(address(0), amount);
    }

    function refresh() internal {
        ltcSource.set(100e8);
        usdSource.set(1e8);
    }

    function absorbAlice() internal {
        address[] memory accounts = new address[](1);
        accounts[0] = alice;
        market.absorb(bob, accounts);
    }

    receive() external payable {}
}

contract LithiumNativeBaseCometTest is NativeBaseFixture {
    function testConfigurationAndNativeSupply() public view {
        assertEq(market.baseToken(), address(0));
        assertEq(market.decimals(), 18);
        assertEq(market.baseScale(), 1e18);
        assertEq(market.numAssets(), 1);
        assertEq(market.getAssetInfo(0).asset, address(usdc));
        assertEq(market.getAssetInfo(0).scale, 1e6);
        assertEq(ext.name(), "Lithium zkLTC");
        assertEq(ext.symbol(), "lizkLTC");
        assertEq(market.totalSupply(), 100 ether);
        assertEq(market.getReserves(), 10 ether);
        assertEq(market.accountedNative(), 110 ether);
        assertEq(market.baseTrackingSupplySpeed(), 0);
        assertEq(market.baseTrackingBorrowSpeed(), 0);
    }

    function testBorrowNativeAgainstUSDCAndRepayWithExcessSupply() public {
        collateral(1000e6);
        uint256 walletBefore = alice.balance;
        borrow(5 ether);
        assertEq(alice.balance, walletBefore + 5 ether);
        assertEq(market.borrowBalanceOf(alice), 5 ether);
        assertEq(ext.collateralBalanceOf(alice, address(usdc)), 1000e6);
        assertEq(market.balanceOf(alice), 0);
        vm.prank(bob);
        market.supplyNativeTo{value: 6 ether}(alice);
        assertEq(market.borrowBalanceOf(alice), 0);
        assertEq(market.balanceOf(alice), 1 ether);
        assertEq(market.balanceOf(bob), 0);
        assertEq(market.accountedNative(), 111 ether);
        vm.prank(alice);
        market.withdraw(address(usdc), 1000e6);
        vm.prank(alice);
        market.withdraw(address(0), type(uint256).max);
        assertEq(market.balanceOf(alice), 0);
        assertEq(market.getReserves(), 10 ether);
    }

    function testBorrowLimitAndMinimum() public {
        collateral(1000e6);
        vm.expectRevert(CometMainInterface.NotCollateralized.selector);
        borrow(6 ether + 1e12);
        vm.expectRevert(CometMainInterface.BorrowTooSmall.selector);
        borrow(1);
        borrow(6 ether);
        assertEq(market.borrowBalanceOf(alice), 6 ether);
    }

    function testInternalBaseTransferCreatesDebtWithoutMovingCash() public {
        collateral(1000e6);
        uint256 cash = market.accountedNative();
        vm.prank(alice);
        market.transfer(bob, 5 ether);
        assertEq(market.borrowBalanceOf(alice), 5 ether);
        assertEq(market.balanceOf(bob), 5 ether);
        assertEq(market.accountedNative(), cash);
        assertEq(market.getReserves(), 10 ether);
        vm.prank(bob);
        market.transfer(alice, 5 ether);
        assertEq(market.borrowBalanceOf(alice), 0);
        assertEq(market.balanceOf(bob), 0);
    }

    function testUnauthorizedThenAuthorizedDelegatedWithdrawal() public {
        collateral(1000e6);
        vm.expectRevert(CometMainInterface.Unauthorized.selector);
        vm.prank(bob);
        market.withdrawFrom(alice, bob, address(0), 1 ether);
        vm.prank(alice);
        ext.allow(bob, true);
        vm.prank(bob);
        market.withdrawFrom(alice, bob, address(0), 1 ether);
        assertEq(market.borrowBalanceOf(alice), 1 ether);
    }

    function testCollateralWithdrawalAndTransferRespectAccruedDebt() public {
        collateral(1000e6);
        borrow(6 ether);
        vm.warp(block.timestamp + 30 days);
        refresh();
        vm.expectRevert(CometMainInterface.NotCollateralized.selector);
        vm.prank(alice);
        market.withdraw(address(usdc), 1);
        vm.expectRevert(CometMainInterface.NotCollateralized.selector);
        vm.prank(alice);
        market.transferAsset(bob, address(usdc), 1);
    }

    function testCollateralCapAndUnsupportedAssetRejected() public {
        collateral(10_000_000e6);
        vm.expectRevert(CometMainInterface.SupplyCapExceeded.selector);
        collateral(1);
        AdditionalMarketToken other = new AdditionalMarketToken(6);
        other.mint(alice, 100e6);
        vm.prank(alice);
        other.approve(address(market), type(uint256).max);
        vm.expectRevert(CometMainInterface.BadAsset.selector);
        vm.prank(alice);
        market.supply(address(other), 100e6);
        assertEq(other.balanceOf(address(market)), 0);
    }

    function testNativeAndCollateralDonationsDoNotCreateClaimsOrSaleInventory() public {
        int256 reserves = market.getReserves();
        new ForceNative{value: 3 ether}(payable(address(market)));
        usdc.mint(address(market), 777e6);
        assertEq(market.excessNative(), 3 ether);
        assertEq(market.getReserves(), reserves);
        assertEq(market.totalSupply(), 100 ether);
        assertEq(market.getCollateralReserves(address(usdc)), 0);
        collateral(100e6);
        vm.prank(alice);
        market.withdraw(address(usdc), 100e6);
        assertEq(market.accountedCollateral(), 0);
        assertEq(usdc.balanceOf(address(market)), 777e6);
        // Forced value cannot be borrowed even when it is the only physical cash left.
        collateral(1_000_000e6);
        borrow(110 ether);
        assertEq(market.accountedNative(), 0);
        assertEq(address(market).balance, 3 ether);
        vm.expectRevert();
        borrow(0.01 ether);
        assertEq(market.borrowBalanceOf(alice), 110 ether);
        vm.prank(alice);
        market.supplyNative{value: 1 ether}();
        borrow(1 ether);
        assertEq(market.accountedNative(), 0);
        assertEq(market.excessNative(), 3 ether);
    }

    function testReserveFundingAndAuthorizedWithdrawal() public {
        market.fundReservesNative{value: 2 ether}();
        assertEq(market.totalSupply(), 100 ether);
        assertEq(market.getReserves(), 12 ether);
        vm.expectRevert(CometMainInterface.Unauthorized.selector);
        vm.prank(alice);
        market.withdrawReserves(alice, 1 ether);
        market.withdrawReserves(bob, 12 ether);
        assertEq(market.getReserves(), 0);
        vm.expectRevert(CometMainInterface.InsufficientReserves.selector);
        market.withdrawReserves(bob, 1);
    }

    function testLTCRiseLiquidationAndNativePaidCollateralSale() public {
        collateral(1000e6);
        borrow(5 ether);
        ltcSource.set(150e8);
        assertTrue(market.isLiquidatable(alice));
        absorbAlice();
        assertEq(market.borrowBalanceOf(alice), 0);
        assertEq(market.balanceOf(alice), 1 ether);
        assertEq(market.getCollateralReserves(address(usdc)), 1000e6);
        assertEq(market.getReserves(), 4 ether);
        uint256 quote = market.quoteCollateral(address(usdc), 1 ether);
        vm.prank(bob);
        market.buyCollateralNative{value: 1 ether}(address(usdc), quote, bob);
        assertEq(usdc.balanceOf(bob), quote);
        assertEq(market.accountedCollateral(), 1000e6 - quote);
        assertEq(market.getReserves(), 5 ether);
        assertEq(market.accountedNative(), address(market).balance);
    }

    function testBadDebtAbsorptionAndStablecoinDepeg() public {
        collateral(4000e6);
        borrow(20 ether);
        usdSource.set(5e7);
        assertTrue(market.isLiquidatable(alice));
        absorbAlice();
        assertEq(market.borrowBalanceOf(alice), 0);
        assertEq(market.balanceOf(alice), 0);
        assertEq(market.getReserves(), -10 ether);
        vm.expectRevert(CometMainInterface.InsufficientReserves.selector);
        market.withdrawReserves(bob, 1);
        uint256 quote = market.quoteCollateral(address(usdc), 1 ether);
        market.buyCollateralNative{value: 1 ether}(address(usdc), quote, bob);
        assertEq(market.getReserves(), -9 ether);
        market.fundReservesNative{value: 19 ether}();
        assertEq(market.getReserves(), 10 ether);
        assertEq(market.totalSupply(), 100 ether);
    }

    function testHealthyAccountCannotBeAbsorbed() public {
        collateral(1000e6);
        borrow(5 ether);
        vm.expectRevert(CometMainInterface.NotLiquidatable.selector);
        absorbAlice();
    }

    function testSaleRequiresValueSlippageAndAvailableInventory() public {
        collateral(1000e6);
        borrow(5 ether);
        ltcSource.set(150e8);
        absorbAlice();
        vm.expectRevert(LithiumNativeBaseComet.NativeSupplyRequired.selector);
        market.buyCollateral(address(usdc), 0, 1 ether, bob);
        vm.expectRevert(LithiumNativeBaseComet.InvalidNativeValue.selector);
        market.buyCollateralNative(address(usdc), 0, bob);
        vm.expectRevert(CometMainInterface.TooMuchSlippage.selector);
        market.buyCollateralNative{value: 1 ether}(address(usdc), 1000e6, bob);
        vm.expectRevert(CometMainInterface.InsufficientReserves.selector);
        market.buyCollateralNative{value: 10 ether}(address(usdc), 0, bob);
        assertEq(market.getReserves(), 4 ether);
    }

    function testSaleUnavailableAtReserveTarget() public {
        vm.expectRevert(CometMainInterface.NotForSale.selector);
        market.buyCollateralNative{value: 1 ether}(address(usdc), 0, bob);
    }

    function testRejectedNativeSendRollsBackDebtAndCash() public {
        collateral(1000e6);
        NativeBaseReceiver receiver = new NativeBaseReceiver(market);
        receiver.configure(true, false);
        vm.expectRevert(LithiumNativeBaseComet.NativeTransferFailed.selector);
        vm.prank(alice);
        market.withdrawTo(address(receiver), address(0), 1 ether);
        assertEq(market.borrowBalanceOf(alice), 0);
        assertEq(market.accountedNative(), 110 ether);
    }

    function testNativeCallbackCannotReenterAccounting() public {
        collateral(1000e6);
        NativeBaseReceiver receiver = new NativeBaseReceiver(market);
        receiver.configure(false, true);
        vm.prank(alice);
        market.withdrawTo(address(receiver), address(0), 1 ether);
        assertFalse(receiver.callbackSucceeded());
        assertEq(receiver.callbackResult(), abi.encodeWithSelector(CometMainInterface.ReentrantCallBlocked.selector));
        assertEq(market.borrowBalanceOf(alice), 1 ether);
    }

    function testTokenCallbackCannotReenterAccounting() public {
        usdc.setCallback(address(market), abi.encodeWithSignature("accrueAccount(address)", alice));
        collateral(1000e6);
        assertFalse(usdc.callbackSucceeded());
        assertEq(usdc.callbackResult(), abi.encodeWithSelector(CometMainInterface.ReentrantCallBlocked.selector));
        assertEq(market.accountedCollateral(), 1000e6);
    }

    function testTaxedCollateralRejectedOnEntryAndExit() public {
        usdc.configure(false, false, true, false);
        vm.expectRevert(CometMainInterface.TransferInFailed.selector);
        collateral(100e6);
        assertEq(market.accountedCollateral(), 0);
        usdc.configure(false, false, false, false);
        collateral(100e6);
        usdc.configure(false, false, true, false);
        vm.expectRevert(CometMainInterface.TransferOutFailed.selector);
        vm.prank(alice);
        market.withdraw(address(usdc), 100e6);
        assertEq(market.accountedCollateral(), 100e6);
        assertEq(ext.collateralBalanceOf(alice, address(usdc)), 100e6);
    }

    function testNoReturnCollateralSupportedAndFalseReturnRejected() public {
        usdc.configure(true, false, false, false);
        collateral(100e6);
        vm.prank(alice);
        market.withdraw(address(usdc), 100e6);
        usdc.configure(false, true, false, false);
        vm.expectRevert(CometMainInterface.TransferInFailed.selector);
        collateral(100e6);
    }

    function testStalePricesBlockBorrowAndAbsorption() public {
        collateral(1000e6);
        borrow(5 ether);
        vm.warp(block.timestamp + 1 hours + 1);
        vm.expectRevert(LithiumCometPriceFeed.InvalidPrice.selector);
        borrow(0.1 ether);
        vm.expectRevert(LithiumCometPriceFeed.InvalidPrice.selector);
        absorbAlice();
        vm.prank(alice);
        market.supplyNative{value: 6 ether}();
        assertEq(market.borrowBalanceOf(alice), 0);
    }

    function testPausedActionsAndGuardianAuthority() public {
        collateral(1000e6);
        vm.expectRevert(CometMainInterface.Unauthorized.selector);
        vm.prank(alice);
        market.pause(true, true, true, true, true);
        vm.prank(guardian);
        market.pause(true, true, true, true, true);
        vm.expectRevert(CometMainInterface.Paused.selector);
        market.supplyNative{value: 1 ether}();
        vm.expectRevert(CometMainInterface.Paused.selector);
        collateral(1);
        vm.expectRevert(CometMainInterface.Paused.selector);
        borrow(1 ether);
        vm.expectRevert(CometMainInterface.Paused.selector);
        market.transfer(bob, 1 ether);
        vm.expectRevert(CometMainInterface.Paused.selector);
        absorbAlice();
        vm.expectRevert(CometMainInterface.Paused.selector);
        market.buyCollateralNative{value: 1 ether}(address(usdc), 0, bob);
        market.fundReservesNative{value: 1 ether}();
        assertEq(market.getReserves(), 11 ether);
    }

    function testInvalidNativePathsAndRecipients() public {
        vm.expectRevert(LithiumNativeBaseComet.InvalidNativeValue.selector);
        market.supplyNative();
        vm.expectRevert(LithiumNativeBaseComet.InvalidNativeValue.selector);
        market.supplyNativeTo{value: 1 ether}(address(0));
        vm.expectRevert(LithiumNativeBaseComet.InvalidNativeValue.selector);
        market.supplyNativeTo{value: 1 ether}(address(market));
        vm.expectRevert(LithiumNativeBaseComet.NativeSupplyRequired.selector);
        market.supply(address(0), 1 ether);
        (bool ok,) = address(market).call{value: 1 ether}("");
        assertFalse(ok);
        vm.expectRevert(CometMainInterface.TransferOutFailed.selector);
        market.withdrawTo(address(0), address(0), 1 ether);
        vm.expectRevert(CometMainInterface.TransferOutFailed.selector);
        market.withdrawTo(address(market), address(0), 1 ether);
    }

    function testTrackedAssetsCannotReceiveExternalAdminAllowances() public {
        vm.expectRevert(CometMainInterface.BadAsset.selector);
        market.approveThis(bob, address(usdc), 1);
        vm.expectRevert(CometMainInterface.BadAsset.selector);
        market.approveThis(bob, address(0), 1);
        vm.expectRevert(CometMainInterface.BadAsset.selector);
        market.approveThis(bob, address(market), 1);
    }

    function testInitializedAtomicallyAndNoReinitialization() public {
        vm.expectRevert(CometMainInterface.AlreadyInitialized.selector);
        market.initializeStorage();
    }

    function testInvalidBaseAndMultipleCollateralConfigurations() public {
        config.baseToken = address(usdc);
        vm.expectRevert(LithiumNativeBaseComet.InvalidConfiguration.selector);
        deployCode("LithiumNativeBaseComet.sol:LithiumNativeBaseComet", abi.encode(config));
        config.baseToken = address(0);
        config.assetConfigs.push(config.assetConfigs[0]);
        vm.expectRevert(LithiumNativeBaseComet.InvalidConfiguration.selector);
        deployCode("LithiumNativeBaseComet.sol:LithiumNativeBaseComet", abi.encode(config));
    }

    function testInvalidCollateralDecimalsAndZeroRiskFactor() public {
        config.assetConfigs[0].decimals = 18;
        vm.expectRevert(LithiumErc20AssetList.InvalidCollateral.selector);
        deployCode("LithiumNativeBaseComet.sol:LithiumNativeBaseComet", abi.encode(config));
        config.assetConfigs[0].decimals = 6;
        config.assetConfigs[0].borrowCollateralFactor = 0;
        vm.expectRevert(LithiumErc20AssetList.InvalidCollateral.selector);
        deployCode("LithiumNativeBaseComet.sol:LithiumNativeBaseComet", abi.encode(config));
    }

    function testFuzzSupplyWithdrawPreservesPrincipalAndReserves(uint96 amount_) public {
        uint256 amount = bound(uint256(amount_), 1, 100 ether);
        vm.prank(bob);
        market.supplyNative{value: amount}();
        assertEq(market.balanceOf(bob), amount);
        vm.prank(bob);
        market.withdraw(address(0), amount);
        assertEq(market.balanceOf(bob), 0);
        assertEq(market.accountedNative(), 110 ether);
        assertEq(market.getReserves(), 10 ether);
    }

    function testFuzzBorrowRepayAndInterest(uint96 amount_, uint32 elapsed_) public {
        collateral(1000e6);
        uint256 amount = bound(uint256(amount_), 0.01 ether, 5 ether);
        borrow(amount);
        vm.warp(block.timestamp + bound(uint256(elapsed_), 1, 365 days));
        refresh();
        uint256 debt = market.borrowBalanceOf(alice);
        assertGt(debt, amount);
        vm.prank(alice);
        market.supplyNative{value: debt}();
        assertEq(market.borrowBalanceOf(alice), 0);
        assertEq(market.accountedNative(), address(market).balance);
        assertGe(market.getReserves(), 10 ether - 2);
    }
}
