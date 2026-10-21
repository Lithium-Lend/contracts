// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.15;
import {LithiumCometFixture} from "./LithiumComet.t.sol";
import {DeployLithiumComet} from "../script/DeployLithiumComet.s.sol";
import {LithiumComet} from "../src/LithiumComet.sol";
import {CometExtInterface} from "comet/CometExtInterface.sol";

contract DeployLithiumCometTest is LithiumCometFixture {
    DeployLithiumComet internal deployer;

    function setUp() public override {
        super.setUp();
        deployer = new DeployLithiumComet();
    }

    function configureEnvironment() internal {
        vm.setEnv("EXPECTED_CHAIN_ID", "4441");
        vm.setEnv("COMET_GOVERNOR", vm.toString(address(this)));
        vm.setEnv("COMET_PAUSE_GUARDIAN", vm.toString(guardian));
        vm.setEnv("COMET_UPGRADE_OWNER", vm.toString(address(this)));
        vm.setEnv("COMET_USDC_ADDRESS", vm.toString(address(usdc)));
        vm.setEnv("COMET_USDC_USD_FEED", vm.toString(address(usdSource)));
        vm.setEnv("COMET_ZKLTC_USD_FEED", vm.toString(address(ltcSource)));
        env("COMET_USDC_MAX_STALENESS", 1 hours);
        env("COMET_ZKLTC_MAX_STALENESS", 1 hours);
        string memory selected = vm.readFile("config/liteforge.rate-update.json");
        string[8] memory rateKeys = [
            "COMET_SUPPLY_KINK",
            "COMET_BORROW_KINK",
            "COMET_SUPPLY_SLOPE_LOW",
            "COMET_SUPPLY_SLOPE_HIGH",
            "COMET_SUPPLY_RATE_BASE",
            "COMET_BORROW_SLOPE_LOW",
            "COMET_BORROW_SLOPE_HIGH",
            "COMET_BORROW_RATE_BASE"
        ];
        for (uint256 i; i < rateKeys.length; i++) {
            vm.setEnv(rateKeys[i], vm.parseJsonString(selected, string.concat(".environment.", rateKeys[i])));
        }
        env("COMET_STOREFRONT_FACTOR", 1e18);
        env("COMET_MINIMUM_BORROW", 1e6);
        env("COMET_TARGET_RESERVES", 1000e6);
        env("COMET_BORROW_COLLATERAL_FACTOR", 75e16);
        env("COMET_LIQUIDATION_COLLATERAL_FACTOR", 8e17);
        env("COMET_LIQUIDATION_FACTOR", 9e17);
        env("COMET_ZKLTC_SUPPLY_CAP", 1000 ether);
    }

    // Environment variables are process-wide, unlike EVM snapshots. Keep all
    // environment-mutating cases in one test so parallel cases cannot race.
    function testDeploymentPreflightAndAtomicInitialization() public {
        configureEnvironment();
        checkDeployInitializesProxyAndSupportsNative();
        vm.chainId(4441);
        vm.warp(1_800_000_000);
        configureEnvironment();
        checkDeployRejectsWrongChain();
        vm.chainId(4441);
        vm.warp(1_800_000_000);
        configureEnvironment();
        checkDeployRejectsExpectedChainMismatch();
        vm.chainId(4441);
        vm.warp(1_800_000_000);
        configureEnvironment();
        checkDeployRejectsZeroOwner();
        vm.chainId(4441);
        vm.warp(1_800_000_000);
        configureEnvironment();
        checkDeployRejectsMissingTokenCode();
        vm.chainId(4441);
        vm.warp(1_800_000_000);
        configureEnvironment();
        checkDeployRejectsStaleFeed();
        vm.chainId(4441);
        vm.warp(1_800_000_000);
        configureEnvironment();
        checkDeployRejectsTruncatedInput();
        vm.chainId(4441);
        vm.warp(1_800_000_000);
        configureEnvironment();
        checkDeployRejectsInvertedCollateralFactors();
        vm.chainId(4441);
        vm.warp(1_800_000_000);
    }

    function env(string memory key, uint256 value) internal {
        vm.setEnv(key, vm.toString(value));
    }

    function checkDeployInitializesProxyAndSupportsNative() internal {
        LithiumComet deployed = deployer.run();
        assertEq(deployed.governor(), address(this));
        assertEq(deployed.baseToken(), address(usdc));
        assertEq(deployed.numAssets(), 1);
        CometExtInterface deployedExtension = CometExtInterface(address(deployed));
        assertEq(deployedExtension.name(), "Lithium USDC");
        assertEq(deployedExtension.symbol(), "liUSDC");
        assertEq(deployed.decimals(), 6);
        assertEq(deployed.borrowPerSecondInterestRateBase(), uint256(36e15) / 365 days);
        assertEq(deployed.supplyKink(), 9e17);
        assertEq(deployed.borrowKink(), 9e17);
        assertEq(deployed.supplyPerSecondInterestRateBase(), 0);
        vm.expectRevert();
        deployed.initializeStorage();
        deployed.supplyNative{value: 1 ether}();
        assertEq(deployed.accountedNative(), 1 ether);
    }

    function checkDeployRejectsWrongChain() internal {
        vm.chainId(1);
        vm.expectRevert(DeployLithiumComet.WrongChain.selector);
        deployer.run();
    }

    function checkDeployRejectsExpectedChainMismatch() internal {
        env("EXPECTED_CHAIN_ID", 1);
        vm.expectRevert(DeployLithiumComet.WrongChain.selector);
        deployer.run();
    }

    function checkDeployRejectsZeroOwner() internal {
        vm.setEnv("COMET_UPGRADE_OWNER", vm.toString(address(0)));
        vm.expectRevert(DeployLithiumComet.InvalidInput.selector);
        deployer.run();
    }

    function checkDeployRejectsMissingTokenCode() internal {
        vm.setEnv("COMET_USDC_ADDRESS", vm.toString(bob));
        vm.expectRevert(DeployLithiumComet.InvalidInput.selector);
        deployer.run();
    }

    function checkDeployRejectsStaleFeed() internal {
        vm.warp(block.timestamp + 1 hours + 1);
        vm.expectRevert(DeployLithiumComet.InvalidInput.selector);
        deployer.run();
    }

    function checkDeployRejectsTruncatedInput() internal {
        env("COMET_SUPPLY_SLOPE_LOW", uint256(type(uint64).max) + 1);
        vm.expectRevert(DeployLithiumComet.InvalidInput.selector);
        deployer.run();
    }

    function checkDeployRejectsInvertedCollateralFactors() internal {
        env("COMET_BORROW_COLLATERAL_FACTOR", 9e17);
        vm.expectRevert(DeployLithiumComet.InvalidInput.selector);
        deployer.run();
    }
}
