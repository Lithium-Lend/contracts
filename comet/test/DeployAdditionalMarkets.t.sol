// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.15;

import {NativeBaseFixture} from "./LithiumNativeBaseComet.t.sol";
import {
    AdditionalMarketDeployment,
    DeployLithiumUSDTComet,
    DeployLithiumNativeBaseComet
} from "../script/DeployAdditionalMarkets.s.sol";
import {CometMainInterface} from "comet/CometMainInterface.sol";
import {CometExtInterface} from "comet/CometExtInterface.sol";
import {LithiumNativeBaseComet} from "../src/LithiumNativeBaseComet.sol";
import {LithiumUSDTComet} from "../src/LithiumUSDTComet.sol";
import {ProxyAdmin} from "comet/vendor/proxy/transparent/ProxyAdmin.sol";

contract DeployAdditionalMarketsTest is NativeBaseFixture {
    function configureEnvironment(bool native) internal {
        env("MARKET_EXPECTED_CHAIN_ID", 4441);
        vm.setEnv("MARKET_GOVERNOR", vm.toString(address(this)));
        vm.setEnv("MARKET_PAUSE_GUARDIAN", vm.toString(guardian));
        vm.setEnv("MARKET_UPGRADE_OWNER", vm.toString(bob));
        vm.setEnv("MARKET_BASE_TOKEN", vm.toString(native ? address(0) : address(usdc)));
        vm.setEnv("MARKET_COLLATERAL_TOKEN", vm.toString(native ? address(usdc) : address(0)));
        vm.setEnv("MARKET_BASE_USD_FEED", vm.toString(native ? address(ltcSource) : address(usdSource)));
        vm.setEnv("MARKET_COLLATERAL_USD_FEED", vm.toString(native ? address(usdSource) : address(ltcSource)));
        env("MARKET_BASE_MAX_STALENESS", 1 hours);
        env("MARKET_COLLATERAL_MAX_STALENESS", 1 hours);
        env("MARKET_SUPPLY_KINK", 8e17);
        env("MARKET_BORROW_KINK", 8e17);
        env("MARKET_SUPPLY_RATE_BASE", 0);
        env("MARKET_SUPPLY_SLOPE_LOW", 3e16);
        env("MARKET_SUPPLY_SLOPE_HIGH", 0);
        env("MARKET_BORROW_RATE_BASE", 4e16);
        env("MARKET_BORROW_SLOPE_LOW", 4e16);
        env("MARKET_BORROW_SLOPE_HIGH", 0);
        env("MARKET_STOREFRONT_FACTOR", 1e18);
        env("MARKET_MINIMUM_BORROW", native ? 0.01 ether : 1e6);
        env("MARKET_TARGET_RESERVES", native ? 10 ether : 100e6);
        env("MARKET_BORROW_COLLATERAL_FACTOR", 6e17);
        env("MARKET_LIQUIDATION_COLLATERAL_FACTOR", 7e17);
        env("MARKET_LIQUIDATION_FACTOR", 9e17);
        env("MARKET_COLLATERAL_SUPPLY_CAP", native ? 10_000_000e6 : 1000 ether);
    }

    function env(string memory key, uint256 value) internal {
        vm.setEnv(key, vm.toString(value));
    }

    // Environment values are process-wide. Keep new-script mutations in one test,
    // using a distinct prefix from the historical deployment tests.
    function testSeparateDeploymentsPreflightAndAtomicInitialization() public {
        AdditionalMarketDeployment nativeDeployer = new DeployLithiumNativeBaseComet();
        AdditionalMarketDeployment stableDeployer = new DeployLithiumUSDTComet();
        configureEnvironment(true);
        CometMainInterface deployed = nativeDeployer.run();
        checkDeployment(deployed, true);
        LithiumNativeBaseComet(payable(address(deployed))).supplyNative{value: 1 ether}();
        assertEq(deployed.balanceOf(address(this)), 1 ether);
        configureEnvironment(false);
        deployed = stableDeployer.run();
        checkDeployment(deployed, false);
        LithiumUSDTComet(payable(address(deployed))).supplyNative{value: 1 ether}();
        assertEq(CometExtInterface(address(deployed)).collateralBalanceOf(address(this), address(0)), 1 ether);
        assertEq(deployed.balanceOf(address(this)), 0);

        configureEnvironment(true);
        vm.chainId(1);
        vm.expectRevert(AdditionalMarketDeployment.WrongChain.selector);
        nativeDeployer.run();
        vm.chainId(4441);
        env("MARKET_EXPECTED_CHAIN_ID", 1);
        vm.expectRevert(AdditionalMarketDeployment.WrongChain.selector);
        nativeDeployer.run();
        configureEnvironment(true);
        vm.setEnv("MARKET_BASE_TOKEN", vm.toString(address(usdc)));
        expectInvalid(nativeDeployer);
        configureEnvironment(false);
        vm.setEnv("MARKET_COLLATERAL_TOKEN", vm.toString(address(usdc)));
        expectInvalid(stableDeployer);
        configureEnvironment(true);
        vm.setEnv("MARKET_UPGRADE_OWNER", vm.toString(address(0)));
        expectInvalid(nativeDeployer);
        configureEnvironment(true);
        vm.setEnv("MARKET_COLLATERAL_TOKEN", vm.toString(bob));
        expectInvalid(nativeDeployer);
        configureEnvironment(true);
        env("MARKET_BORROW_SLOPE_HIGH", uint256(type(uint64).max) + 1);
        expectInvalid(nativeDeployer);
        configureEnvironment(true);
        env("MARKET_BORROW_COLLATERAL_FACTOR", 8e17);
        expectInvalid(nativeDeployer);
        configureEnvironment(true);
        vm.warp(block.timestamp + 1 hours + 1);
        expectInvalid(nativeDeployer);
    }

    function expectInvalid(AdditionalMarketDeployment deployer) internal {
        vm.expectRevert(AdditionalMarketDeployment.InvalidInput.selector);
        deployer.run();
    }

    function checkDeployment(CometMainInterface deployed, bool native) internal {
        assertEq(deployed.governor(), address(this));
        assertEq(deployed.pauseGuardian(), guardian);
        assertEq(deployed.baseToken(), native ? address(0) : address(usdc));
        assertEq(deployed.getAssetInfo(0).asset, native ? address(usdc) : address(0));
        assertEq(deployed.numAssets(), 1);
        assertEq(deployed.decimals(), native ? 18 : 6);
        assertEq(deployed.targetReserves(), native ? 10 ether : 100e6);
        assertEq(deployed.baseBorrowMin(), native ? 0.01 ether : 1e6);
        assertEq(deployed.getPrice(deployed.baseTokenPriceFeed()), native ? 100e8 : 1e8);
        assertEq(CometExtInterface(address(deployed)).symbol(), native ? "lizkLTC" : "liUSDT");
        assertEq(deployed.baseTrackingSupplySpeed(), 0);
        assertEq(deployed.baseTrackingBorrowSpeed(), 0);
        bytes32 adminSlot = bytes32(uint256(keccak256("eip1967.proxy.admin")) - 1);
        address admin = address(uint160(uint256(vm.load(address(deployed), adminSlot))));
        assertEq(ProxyAdmin(admin).owner(), bob);
        vm.expectRevert(CometMainInterface.AlreadyInitialized.selector);
        deployed.initializeStorage();
    }
}
