// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.15;

import {Test} from "forge-std/Test.sol";
import {LithiumComet} from "../src/LithiumComet.sol";
import {LithiumCometPriceFeed} from "../src/LithiumCometPriceFeed.sol";
import {LithiumNativeAssetList} from "../src/LithiumNativeAssetList.sol";
import {CometConfiguration} from "comet/CometConfiguration.sol";
import {CometExt} from "comet/CometExt.sol";
import {CometExtInterface} from "comet/CometExtInterface.sol";
import {TransparentUpgradeableProxy} from "comet/vendor/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IPriceFeed} from "comet/interfaces/IPriceFeed.sol";

contract MockUSDC {
    uint8 public decimals = 6;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    bool public taxed;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function setTax(bool value) external {
        taxed = value;
    }

    function approve(address to, uint256 amount) external returns (bool) {
        allowance[msg.sender][to] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (allowance[from][msg.sender] != type(uint256).max) allowance[from][msg.sender] -= amount;
        move(from, to, amount);
        return true;
    }

    function move(address from, address to, uint256 amount) internal {
        balanceOf[from] -= amount;
        balanceOf[to] += taxed ? amount * 99 / 100 : amount;
    }
}

contract MockFeed is IPriceFeed {
    uint8 public override decimals = 8;
    string public override description = "Test USD price";
    uint256 public override version = 1;
    int256 public price;
    uint256 public updatedAt;
    uint80 public round = 1;
    uint80 public answered = 1;

    constructor(int256 price_) {
        set(price_);
    }

    function set(int256 price_) public {
        price = price_;
        updatedAt = block.timestamp;
    }

    function setTime(uint256 t) external {
        updatedAt = t;
    }

    function setAnswered(uint80 a) external {
        answered = a;
    }

    function setDecimals(uint8 d) external {
        decimals = d;
    }

    function latestRoundData() external view override returns (uint80, int256, uint256, uint256, uint80) {
        return (round, price, updatedAt, updatedAt, answered);
    }
}

contract ForceNative {
    constructor(address payable to) payable {
        selfdestruct(to);
    }
}

contract NativeReceiver {
    LithiumComet public comet;
    bool public reject;
    bool public reenter;
    bool public callbackSucceeded;

    constructor(LithiumComet comet_) {
        comet = comet_;
    }

    function deposit() external payable {
        comet.supplyNative{value: msg.value}();
    }

    function withdraw(uint256 amount) external {
        comet.withdraw(address(0), amount);
    }

    function configure(bool reject_, bool reenter_) external {
        reject = reject_;
        reenter = reenter_;
    }

    receive() external payable {
        require(!reject, "Reject native");
        if (reenter) {
            (callbackSucceeded,) =
                address(comet).call(abi.encodeWithSignature("withdraw(address,uint256)", address(0), 1));
        }
    }
}

abstract contract LithiumCometFixture is Test {
    LithiumComet internal comet;
    CometExtInterface internal ext;
    MockUSDC internal usdc;
    MockFeed internal usdSource;
    MockFeed internal ltcSource;
    LithiumCometPriceFeed internal usdFeed;
    LithiumCometPriceFeed internal ltcFeed;
    CometConfiguration.Configuration internal config;
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal guardian = address(0xCAFE);
    address internal proxyAdmin = address(0xAD);
    address internal implementation;

    function setUp() public virtual {
        vm.warp(1_800_000_000);
        vm.chainId(4441);
        usdc = new MockUSDC();
        usdSource = new MockFeed(1e8);
        ltcSource = new MockFeed(100e8);
        usdFeed = new LithiumCometPriceFeed(address(usdSource), 1 hours);
        ltcFeed = new LithiumCometPriceFeed(address(ltcSource), 1 hours);
        config.governor = address(this);
        config.pauseGuardian = guardian;
        config.baseToken = address(usdc);
        config.baseTokenPriceFeed = address(usdFeed);
        config.extensionDelegate =
            address(new CometExt(CometConfiguration.ExtConfiguration(bytes32("Lithium USDC"), bytes32("liUSDC"))));
        config.supplyKink = 8e17;
        config.borrowKink = 8e17;
        config.supplyPerYearInterestRateBase = 2e16;
        config.borrowPerYearInterestRateBase = 5e16;
        config.storeFrontPriceFactor = 1e18;
        config.trackingIndexScale = 1e15;
        config.baseMinForRewards = 1e6;
        config.baseBorrowMin = 1e6;
        config.targetReserves = 1000e6;
        config.assetConfigs
            .push(CometConfiguration.AssetConfig(address(0), address(ltcFeed), 18, 75e16, 8e17, 9e17, 1000 ether));
        implementation = deployCode("LithiumComet.sol:LithiumComet", abi.encode(config));
        comet = LithiumComet(
            payable(address(
                    new TransparentUpgradeableProxy(
                        implementation, proxyAdmin, abi.encodeWithSignature("initializeStorage()")
                    )
                ))
        );
        ext = CometExtInterface(address(comet));
        vm.deal(alice, 10_000 ether);
        vm.deal(bob, 10_000 ether);
        vm.deal(address(this), 10_000 ether);
        usdc.mint(address(this), 2_000_000e6);
        usdc.approve(address(comet), type(uint256).max);
        comet.supply(address(usdc), 100_000e6);
        usdc.mint(alice, 2_000_000e6);
        vm.prank(alice);
        usdc.approve(address(comet), type(uint256).max);
    }

    function deposit(address user, uint256 amount) internal {
        vm.prank(user);
        comet.supplyNative{value: amount}();
    }

    function borrow(uint256 amount) internal {
        vm.prank(alice);
        comet.withdraw(address(usdc), amount);
    }

    function refresh() internal {
        usdSource.set(1e8);
        ltcSource.set(100e8);
    }

    function liquidate() internal {
        deposit(alice, 1 ether);
        borrow(70e6);
        ltcSource.set(50e8);
        address[] memory users = new address[](1);
        users[0] = alice;
        comet.absorb(bob, users);
    }
}

contract LithiumCometTest is LithiumCometFixture {
    function testUpgradePreservesUserAndNativeStorage() public {
        deposit(alice, 2 ether);
        borrow(70e6);
        vm.prank(alice);
        ext.allow(bob, true);
        uint256 suppliedBefore = comet.balanceOf(address(this));
        address replacement = deployCode("LithiumComet.sol:LithiumComet", abi.encode(config));
        vm.prank(proxyAdmin);
        TransparentUpgradeableProxy(payable(address(comet))).upgradeTo(replacement);
        assertEq(comet.borrowBalanceOf(alice), 70e6);
        assertEq(comet.balanceOf(address(this)), suppliedBefore);
        assertEq(ext.collateralBalanceOf(alice, address(0)), 2 ether);
        assertEq(comet.accountedNative(), 2 ether);
        assertEq(comet.baseToken(), address(usdc));
        vm.prank(bob);
        comet.withdrawFrom(alice, bob, address(0), 0.5 ether);
        assertEq(comet.accountedNative(), 1.5 ether);
    }

    function testUnauthorizedUpgradeRejected() public {
        vm.expectRevert();
        vm.prank(alice);
        TransparentUpgradeableProxy(payable(address(comet))).upgradeTo(implementation);
    }

    function testConfigurationAndExtension() public view {
        assertEq(comet.numAssets(), 1);
        assertEq(comet.baseToken(), address(usdc));
        assertEq(comet.getAssetInfo(0).asset, address(0));
        assertEq(ext.name(), "Lithium USDC");
        assertEq(comet.baseTrackingSupplySpeed(), 0);
        assertEq(comet.baseTrackingBorrowSpeed(), 0);
    }

    function testCannotInitializeProxyTwice() public {
        vm.expectRevert();
        comet.initializeStorage();
    }

    function testNativeDepositCreatesOnlyCollateral() public {
        deposit(alice, 2 ether);
        assertEq(ext.collateralBalanceOf(alice, address(0)), 2 ether);
        assertEq(comet.balanceOf(alice), 0);
        assertEq(comet.accountedNative(), 2 ether);
    }

    function testNativeSupplyToUsesCallerFunds() public {
        vm.prank(alice);
        comet.supplyNativeTo{value: 1 ether}(bob);
        assertEq(ext.collateralBalanceOf(bob, address(0)), 1 ether);
        assertEq(ext.collateralBalanceOf(alice, address(0)), 0);
    }

    function testZeroNativeDepositRejected() public {
        vm.expectRevert(LithiumComet.InvalidNativeValue.selector);
        comet.supplyNative();
    }

    function testNativeDepositToZeroRejected() public {
        vm.expectRevert(LithiumComet.InvalidNativeValue.selector);
        comet.supplyNativeTo{value: 1 ether}(address(0));
    }

    function testNativeDepositToCometRejected() public {
        vm.expectRevert(LithiumComet.InvalidNativeValue.selector);
        comet.supplyNativeTo{value: 1 ether}(address(comet));
    }

    function testRawNativeSendRejected() public {
        (bool ok,) = address(comet).call{value: 1 ether}("");
        assertFalse(ok);
        assertEq(comet.accountedNative(), 0);
    }

    function testERC20SupplyCannotCreditNative() public {
        vm.expectRevert(LithiumComet.NativeSupplyRequired.selector);
        comet.supply(address(0), 1 ether);
    }

    function testUnsupportedCollateralRejected() public {
        vm.expectRevert();
        comet.supply(address(0x1234), 1 ether);
    }

    function testNativeCapBoundary() public {
        deposit(alice, 1000 ether);
        assertEq(comet.accountedNative(), 1000 ether);
    }

    function testNativeCapExceeded() public {
        vm.expectRevert();
        deposit(alice, 1000 ether + 1);
    }

    function testLargeBaseSupply() public {
        comet.supply(address(usdc), 900_000e6);
        assertEq(comet.totalSupply(), 1_000_000e6);
    }

    function testBaseSupplyAboveFormerLimit() public {
        comet.supply(address(usdc), 900_000e6 + 1);
        assertEq(comet.totalSupply(), 1_000_000e6 + 1);
        assertEq(usdc.balanceOf(address(comet)), 1_000_000e6 + 1);
    }

    function testBaseSupplyEarnsInterest() public {
        uint256 beforeBalance = comet.balanceOf(address(this));
        vm.warp(block.timestamp + 365 days);
        comet.accrueAccount(address(this));
        assertGt(comet.balanceOf(address(this)), beforeBalance);
    }

    function testNativeCollateralDoesNotEarnInterest() public {
        deposit(alice, 1 ether);
        vm.warp(block.timestamp + 365 days);
        comet.accrueAccount(alice);
        assertEq(ext.collateralBalanceOf(alice, address(0)), 1 ether);
        assertEq(comet.balanceOf(alice), 0);
    }

    function testBorrowUSDCWithNativeCollateral() public {
        deposit(alice, 1 ether);
        borrow(70e6);
        assertEq(comet.borrowBalanceOf(alice), 70e6);
    }

    function testCannotBorrowNative() public {
        vm.expectRevert();
        vm.prank(alice);
        comet.withdraw(address(0), 1);
    }

    function testCannotBorrowWithoutCollateral() public {
        vm.expectRevert();
        borrow(1e6);
    }

    function testBorrowAboveCollateralFactorRejected() public {
        deposit(alice, 1 ether);
        vm.expectRevert();
        borrow(76e6);
    }

    function testMinimumBorrowEnforced() public {
        deposit(alice, 1 ether);
        vm.expectRevert();
        borrow(1e6 - 1);
    }

    function testBaseBorrowAndDebtTransferAboveFormerLimit() public {
        ltcSource.set(1000e8);
        deposit(alice, 1000 ether);
        comet.supply(address(usdc), 100_000e6);
        borrow(150_000e6);
        vm.prank(alice);
        comet.transfer(bob, 150_000e6);
        assertEq(comet.borrowBalanceOf(alice), 300_000e6);
        assertEq(comet.balanceOf(bob), 150_000e6);
        assertEq(usdc.balanceOf(address(comet)), 50_000e6);
        vm.expectRevert();
        borrow(450_000e6 + 1); // Collateral checks still apply.
    }

    function testTransferCreatesSupplyAboveFormerLimit() public {
        comet.supply(address(usdc), 900_000e6);
        deposit(alice, 1 ether);
        vm.prank(alice);
        comet.transfer(bob, 1e6);
        assertEq(comet.totalSupply(), 1_000_001e6);
        assertEq(comet.borrowBalanceOf(alice), 1e6);
        assertEq(comet.balanceOf(bob), 1e6);
    }

    function testPartialAndFullRepayment() public {
        deposit(alice, 1 ether);
        borrow(70e6);
        vm.prank(alice);
        comet.supply(address(usdc), 20e6);
        assertEq(comet.borrowBalanceOf(alice), 50e6);
        vm.prank(alice);
        comet.supply(address(usdc), type(uint256).max);
        assertEq(comet.borrowBalanceOf(alice), 0);
    }

    function testOverpaymentBecomesInterestBearingSupply() public {
        deposit(alice, 1 ether);
        borrow(70e6);
        vm.prank(alice);
        comet.supply(address(usdc), 80e6);
        assertEq(comet.borrowBalanceOf(alice), 0);
        assertEq(comet.balanceOf(alice), 10e6);
    }

    function testRepaymentAfterInterestOnLargeSupply() public {
        comet.supply(address(usdc), 900_000e6);
        deposit(alice, 1 ether);
        borrow(70e6);
        vm.warp(block.timestamp + 365 days);
        refresh();
        comet.accrueAccount(alice);
        assertGt(comet.totalSupply(), 1_000_000e6);
        vm.prank(alice);
        comet.supply(address(usdc), type(uint256).max);
        assertEq(comet.borrowBalanceOf(alice), 0);
    }

    function testWithdrawNativeAndConserveBalances() public {
        deposit(alice, 2 ether);
        uint256 beforeBalance = alice.balance;
        vm.prank(alice);
        comet.withdraw(address(0), 1 ether);
        assertEq(alice.balance, beforeBalance + 1 ether);
        assertEq(comet.accountedNative(), 1 ether);
        assertEq(ext.collateralBalanceOf(alice, address(0)), 1 ether);
    }

    function testCollateralWithdrawalCannotUndercollateralize() public {
        deposit(alice, 1 ether);
        borrow(70e6);
        vm.expectRevert();
        vm.prank(alice);
        comet.withdraw(address(0), 0.1 ether);
    }

    function testCollateralWithdrawalAccruesDormantDebt() public {
        deposit(alice, 1 ether);
        borrow(70e6);
        vm.warp(block.timestamp + 2 * 365 days);
        refresh();
        vm.expectRevert();
        vm.prank(alice);
        comet.withdraw(address(0), 0.01 ether);
    }

    function testCollateralTransferAccruesDormantDebt() public {
        deposit(alice, 1 ether);
        borrow(70e6);
        vm.warp(block.timestamp + 2 * 365 days);
        refresh();
        vm.expectRevert();
        vm.prank(alice);
        comet.transferAsset(bob, address(0), 0.01 ether);
    }

    function testCollateralTransferConservesTotal() public {
        deposit(alice, 2 ether);
        vm.prank(alice);
        comet.transferAsset(bob, address(0), 1 ether);
        assertEq(ext.collateralBalanceOf(alice, address(0)), 1 ether);
        assertEq(ext.collateralBalanceOf(bob, address(0)), 1 ether);
        assertEq(comet.accountedNative(), 2 ether);
    }

    function testUnapprovedManagerRejected() public {
        deposit(alice, 1 ether);
        vm.expectRevert();
        vm.prank(bob);
        comet.withdrawFrom(alice, bob, address(0), 1 ether);
    }

    function testManagerPermissionAndRevocation() public {
        deposit(alice, 2 ether);
        vm.prank(alice);
        ext.allow(bob, true);
        vm.prank(bob);
        comet.withdrawFrom(alice, bob, address(0), 1 ether);
        vm.prank(alice);
        ext.allow(bob, false);
        vm.expectRevert();
        vm.prank(bob);
        comet.withdrawFrom(alice, bob, address(0), 1 ether);
    }

    function testSupplyPauseIncludesNative() public {
        vm.prank(guardian);
        comet.pause(true, false, false, false, false);
        vm.expectRevert();
        deposit(alice, 1 ether);
        vm.expectRevert();
        comet.supply(address(usdc), 1e6);
    }

    function testWithdrawPauseIncludesNative() public {
        deposit(alice, 1 ether);
        comet.pause(false, false, true, false, false);
        vm.expectRevert();
        vm.prank(alice);
        comet.withdraw(address(0), 1 ether);
    }

    function testUnauthorizedPauseRejected() public {
        vm.expectRevert();
        vm.prank(alice);
        comet.pause(true, true, true, true, true);
    }

    function testForcedNativeCannotCreateCollateralOrSaleInventory() public {
        deposit(alice, 1 ether);
        new ForceNative{value: 20 ether}(payable(address(comet)));
        assertEq(comet.accountedNative(), 1 ether);
        assertEq(comet.excessNative(), 20 ether);
        assertEq(comet.getCollateralReserves(address(0)), 0);
        assertEq(ext.collateralBalanceOf(alice, address(0)), 1 ether);
        vm.expectRevert();
        comet.buyCollateral(address(0), 0, 1e6, bob);
    }

    function testBaseDonationDoesNotIncreaseClaimsOrBorrowPower() public {
        deposit(alice, 1 ether);
        uint256 supplied = comet.balanceOf(address(this));
        usdc.transfer(address(comet), 100_000e6);
        assertEq(comet.balanceOf(address(this)), supplied);
        assertEq(comet.getReserves(), int256(100_000e6));
        vm.expectRevert();
        borrow(76e6);
    }

    function testTaxedBaseRejected() public {
        usdc.setTax(true);
        vm.expectRevert();
        comet.supply(address(usdc), 100e6);
    }

    function testRejectingReceiverRollsBackWithdrawal() public {
        NativeReceiver receiver = new NativeReceiver(comet);
        receiver.deposit{value: 1 ether}();
        receiver.configure(true, false);
        vm.expectRevert(LithiumComet.NativeTransferFailed.selector);
        receiver.withdraw(1 ether);
        assertEq(ext.collateralBalanceOf(address(receiver), address(0)), 1 ether);
        assertEq(comet.accountedNative(), 1 ether);
    }

    function testNativeCallbackCannotReenter() public {
        NativeReceiver receiver = new NativeReceiver(comet);
        receiver.deposit{value: 2 ether}();
        receiver.configure(false, true);
        receiver.withdraw(1 ether);
        assertFalse(receiver.callbackSucceeded());
        assertEq(comet.accountedNative(), 1 ether);
    }

    function testLiquidationMovesNativeToReservesAndClearsDebt() public {
        liquidate();
        assertEq(comet.borrowBalanceOf(alice), 0);
        assertEq(ext.collateralBalanceOf(alice, address(0)), 0);
        assertEq(comet.getCollateralReserves(address(0)), 1 ether);
        assertEq(comet.accountedNative(), 1 ether);
    }

    function testHealthyPositionCannotBeAbsorbed() public {
        deposit(alice, 1 ether);
        borrow(70e6);
        address[] memory users = new address[](1);
        users[0] = alice;
        vm.expectRevert();
        comet.absorb(bob, users);
    }

    function testLiquidationSalePaysNativeAndRestoresBaseReserves() public {
        liquidate();
        uint256 beforeBalance = bob.balance;
        comet.buyCollateral(address(0), 1 ether, 45e6, bob);
        assertEq(bob.balance, beforeBalance + 1 ether);
        assertEq(comet.accountedNative(), 0);
        assertEq(comet.getCollateralReserves(address(0)), 0);
    }

    function testSaleSlippageRevertsAtomically() public {
        liquidate();
        uint256 cash = usdc.balanceOf(address(comet));
        vm.expectRevert();
        comet.buyCollateral(address(0), 1 ether + 1, 45e6, bob);
        assertEq(usdc.balanceOf(address(comet)), cash);
        assertEq(comet.accountedNative(), 1 ether);
    }

    function testSaleCannotConsumeUserCollateral() public {
        liquidate();
        deposit(bob, 1 ether);
        vm.expectRevert();
        comet.buyCollateral(address(0), 0, 90e6, bob);
        assertEq(ext.collateralBalanceOf(bob, address(0)), 1 ether);
    }

    function testSalePause() public {
        liquidate();
        comet.pause(false, false, false, false, true);
        vm.expectRevert();
        comet.buyCollateral(address(0), 0, 45e6, bob);
    }

    function testAbsorbPause() public {
        deposit(alice, 1 ether);
        borrow(70e6);
        ltcSource.set(50e8);
        comet.pause(false, false, false, true, false);
        address[] memory users = new address[](1);
        users[0] = alice;
        vm.expectRevert();
        comet.absorb(bob, users);
    }

    function testGovernorCannotApproveBaseTokenDrain() public {
        vm.expectRevert(bytes4(keccak256("BadAsset()")));
        comet.approveThis(bob, address(usdc), 1e6);
    }

    function testStalePriceBlocksBorrowButAllowsRepayment() public {
        deposit(alice, 1 ether);
        borrow(70e6);
        vm.warp(block.timestamp + 1 hours + 1);
        vm.expectRevert(LithiumCometPriceFeed.InvalidPrice.selector);
        borrow(1e6);
        vm.prank(alice);
        comet.supply(address(usdc), 1e6);
        assertLt(comet.borrowBalanceOf(alice), 70e6);
    }

    function testInvalidNegativePrice() public {
        ltcSource.set(-1);
        vm.expectRevert(LithiumCometPriceFeed.InvalidPrice.selector);
        ltcFeed.latestRoundData();
    }

    function testNormalizesEighteenDecimalDIAFeed() public {
        ltcSource.setDecimals(18);
        ltcSource.set(100e18);
        LithiumCometPriceFeed adapter = new LithiumCometPriceFeed(address(ltcSource), 1 hours);
        (, int256 price,,,) = adapter.latestRoundData();
        assertEq(price, 100e8);
        assertEq(adapter.decimals(), 8);
    }

    function testNormalizesSixDecimalFeed() public {
        ltcSource.setDecimals(6);
        ltcSource.set(100e6);
        LithiumCometPriceFeed adapter = new LithiumCometPriceFeed(address(ltcSource), 1 hours);
        (, int256 price,,,) = adapter.latestRoundData();
        assertEq(price, 100e8);
    }

    function testNormalizedZeroRejected() public {
        ltcSource.setDecimals(18);
        ltcSource.set(1);
        LithiumCometPriceFeed adapter = new LithiumCometPriceFeed(address(ltcSource), 1 hours);
        vm.expectRevert(LithiumCometPriceFeed.InvalidPrice.selector);
        adapter.latestRoundData();
    }

    function testNormalizationOverflowRejected() public {
        ltcSource.setDecimals(6);
        ltcSource.set(type(int256).max);
        LithiumCometPriceFeed adapter = new LithiumCometPriceFeed(address(ltcSource), 1 hours);
        vm.expectRevert(LithiumCometPriceFeed.InvalidPrice.selector);
        adapter.latestRoundData();
    }

    function testUnsupportedFeedDecimalsRejected() public {
        ltcSource.setDecimals(37);
        vm.expectRevert(LithiumCometPriceFeed.InvalidFeed.selector);
        new LithiumCometPriceFeed(address(ltcSource), 1 hours);
    }

    function testInvalidZeroPrice() public {
        ltcSource.set(0);
        vm.expectRevert(LithiumCometPriceFeed.InvalidPrice.selector);
        ltcFeed.latestRoundData();
    }

    function testInvalidFutureTimestamp() public {
        ltcSource.setTime(block.timestamp + 1);
        vm.expectRevert(LithiumCometPriceFeed.InvalidPrice.selector);
        ltcFeed.latestRoundData();
    }

    function testInvalidMissingTimestamp() public {
        ltcSource.setTime(0);
        vm.expectRevert(LithiumCometPriceFeed.InvalidPrice.selector);
        ltcFeed.latestRoundData();
    }

    function testInvalidIncompleteRound() public {
        ltcSource.setAnswered(0);
        vm.expectRevert(LithiumCometPriceFeed.InvalidPrice.selector);
        ltcFeed.latestRoundData();
    }

    function testPriceFreshnessBoundary() public {
        vm.warp(block.timestamp + 1 hours);
        (, int256 p,,,) = ltcFeed.latestRoundData();
        assertEq(p, 100e8);
    }

    function testInvalidConfigurationRejectsAdditionalCollateral() public {
        config.assetConfigs.push(config.assetConfigs[0]);
        vm.expectRevert();
        new LithiumComet(config);
    }

    function testInvalidConfigurationRejectsRewards() public {
        config.baseTrackingSupplySpeed = 1;
        vm.expectRevert(LithiumComet.InvalidConfiguration.selector);
        new LithiumComet(config);
    }

    function testInvalidCollateralFactorsRejected() public {
        config.assetConfigs[0].borrowCollateralFactor = 8e17;
        vm.expectRevert(LithiumNativeAssetList.InvalidNativeAsset.selector);
        new LithiumNativeAssetList(config.assetConfigs[0]);
    }

    function testFuzzNativeConservation(uint96 amount_, uint96 donation_) public {
        uint256 amount = bound(uint256(amount_), 1, 1000 ether);
        uint256 donation = bound(uint256(donation_), 0, 1000 ether);
        deposit(alice, amount);
        new ForceNative{value: donation}(payable(address(comet)));
        vm.prank(alice);
        comet.withdraw(address(0), amount);
        assertEq(comet.accountedNative(), 0);
        assertEq(comet.excessNative(), donation);
        assertEq(ext.collateralBalanceOf(alice, address(0)), 0);
    }

    function testFuzzNativeTransferConservation(uint96 amount_, uint96 part_) public {
        uint256 amount = bound(uint256(amount_), 1, 1000 ether);
        uint256 part = bound(uint256(part_), 0, amount);
        deposit(alice, amount);
        vm.prank(alice);
        comet.transferAsset(bob, address(0), part);
        assertEq(uint256(ext.collateralBalanceOf(alice, address(0))) + ext.collateralBalanceOf(bob, address(0)), amount);
        assertEq(address(comet).balance, comet.accountedNative());
    }
}
