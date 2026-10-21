// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.15;

import {Test} from "forge-std/Test.sol";
import {LithiumComet} from "../src/LithiumComet.sol";
import {LithiumCometPriceFeed} from "../src/LithiumCometPriceFeed.sol";
import {CometConfiguration} from "comet/CometConfiguration.sol";
import {CometExt} from "comet/CometExt.sol";
import {CometExtInterface} from "comet/CometExtInterface.sol";
import {TransparentUpgradeableProxy} from "comet/vendor/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IPriceFeed} from "comet/interfaces/IPriceFeed.sol";

interface BridgedUsdc {
    function decimals() external view returns (uint8);
    function l1Address() external view returns (address);
    function l2Gateway() external view returns (address);
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function bridgeMint(address, uint256) external;
}

interface NativeGateway {
    function calculateL2TokenAddress(address) external view returns (address);
}

/// @dev Opt-in fork tests run entirely in Foundry's local EVM. No transactions
/// are broadcast and no real holder funds are moved.
contract LiteForgeCometForkTest is Test {
    address constant USDC = 0x5adf1045C4a7C3e2176DbCbD09a7E6D1b0f75cfB;
    address constant PARENT_USDC = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
    address constant USDC_SOURCE = 0x4f91a950ed73c8B6F28dFE460f9444ed8866894f;
    address constant LTC_SOURCE = 0x45dDa5d881BD2C917976CCfde74fFd6f6412da29;
    address constant HOLDER = 0x4d02aF17A29cdA77416A1F60Eae9092BB6d9c026;
    address constant BORROWER = address(0xA11CE);
    BridgedUsdc constant usdc = BridgedUsdc(USDC);
    LithiumComet comet;
    LithiumCometPriceFeed baseFeed;
    LithiumCometPriceFeed collateralFeed;
    CometExtInterface ext;
    string proposal;

    function configured(string memory key) internal view returns (uint256) {
        return vm.parseUint(vm.parseJsonString(proposal, string.concat(".environment.", key)));
    }

    function setUp() public {
        if (!vm.envOr("LITHIUM_COMET_FORK", false)) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork("litvm_liteforge", vm.envOr("LITHIUM_COMET_FORK_BLOCK", uint256(50866808)));
        // The deployed DIA receiver uses newer opcodes. This changes local
        // execution only; the Comet compiler target remains London.
        vm.setEvmVersion("prague");
        require(block.chainid == 4441, "Not LiteForge");
        proposal = vm.readFile("config/liteforge.rate-update.json");
        assertEq(vm.parseJsonAddress(proposal, ".environment.COMET_USDC_ADDRESS"), USDC);
        assertEq(vm.parseJsonAddress(proposal, ".environment.COMET_USDC_USD_FEED"), USDC_SOURCE);
        assertEq(vm.parseJsonAddress(proposal, ".environment.COMET_ZKLTC_USD_FEED"), LTC_SOURCE);
        baseFeed = new LithiumCometPriceFeed(USDC_SOURCE, configured("COMET_USDC_MAX_STALENESS"));
        collateralFeed = new LithiumCometPriceFeed(LTC_SOURCE, configured("COMET_ZKLTC_MAX_STALENESS"));
        CometConfiguration.Configuration memory config;
        config.governor = address(this);
        config.pauseGuardian = address(this);
        config.baseToken = USDC;
        config.baseTokenPriceFeed = address(baseFeed);
        config.extensionDelegate =
            address(new CometExt(CometConfiguration.ExtConfiguration(bytes32("Lithium USDC"), bytes32("liUSDC"))));
        // Test the same parameter file consumed by deployment simulation.
        config.supplyKink = uint64(configured("COMET_SUPPLY_KINK"));
        config.borrowKink = uint64(configured("COMET_BORROW_KINK"));
        config.supplyPerYearInterestRateBase = uint64(configured("COMET_SUPPLY_RATE_BASE"));
        config.supplyPerYearInterestRateSlopeLow = uint64(configured("COMET_SUPPLY_SLOPE_LOW"));
        config.supplyPerYearInterestRateSlopeHigh = uint64(configured("COMET_SUPPLY_SLOPE_HIGH"));
        config.borrowPerYearInterestRateBase = uint64(configured("COMET_BORROW_RATE_BASE"));
        config.borrowPerYearInterestRateSlopeLow = uint64(configured("COMET_BORROW_SLOPE_LOW"));
        config.borrowPerYearInterestRateSlopeHigh = uint64(configured("COMET_BORROW_SLOPE_HIGH"));
        config.storeFrontPriceFactor = uint64(configured("COMET_STOREFRONT_FACTOR"));
        config.trackingIndexScale = 1e15;
        config.baseMinForRewards = 1e6;
        config.baseBorrowMin = uint104(configured("COMET_MINIMUM_BORROW"));
        config.targetReserves = uint104(configured("COMET_TARGET_RESERVES"));
        config.assetConfigs = new CometConfiguration.AssetConfig[](1);
        config.assetConfigs[0] = CometConfiguration.AssetConfig(
            address(0),
            address(collateralFeed),
            18,
            uint64(configured("COMET_BORROW_COLLATERAL_FACTOR")),
            uint64(configured("COMET_LIQUIDATION_COLLATERAL_FACTOR")),
            uint64(configured("COMET_LIQUIDATION_FACTOR")),
            uint128(configured("COMET_ZKLTC_SUPPLY_CAP"))
        );
        address implementation = deployCode("LithiumComet.sol:LithiumComet", abi.encode(config));
        comet = LithiumComet(
            payable(address(
                    new TransparentUpgradeableProxy(
                        implementation, address(0xAD), abi.encodeWithSignature("initializeStorage()")
                    )
                ))
        );
        ext = CometExtInterface(address(comet));

        // Local fork impersonation supplies real token bytecode with existing balances.
        vm.prank(HOLDER);
        require(usdc.transfer(address(this), 1500e6), "Fixture transfer failed");
        usdc.approve(address(comet), type(uint256).max);
        vm.deal(BORROWER, 1 ether);
    }

    function openPosition() internal {
        comet.supply(USDC, 100e6);
        vm.startPrank(BORROWER);
        comet.supplyNative{value: 1 ether}();
        comet.withdraw(USDC, 10e6);
        usdc.approve(address(comet), type(uint256).max);
        vm.stopPrank();
    }

    function testForkTokenAndGatewayMapping() public view {
        assertEq(usdc.decimals(), 6);
        assertEq(usdc.l1Address(), PARENT_USDC);
        address gateway = usdc.l2Gateway();
        assertGt(gateway.code.length, 0);
        assertEq(NativeGateway(gateway).calculateL2TokenAddress(PARENT_USDC), USDC);
    }

    function testForkSelectedBorrowBaseAndUnchangedSupplierCurve() public view {
        assertEq(comet.borrowPerSecondInterestRateBase(), uint256(36e15) / 365 days);
        string memory original = vm.readFile("config/liteforge.proposed.json");
        assertEq(
            comet.supplyPerSecondInterestRateSlopeLow(),
            vm.parseUint(vm.parseJsonString(original, ".environment.COMET_SUPPLY_SLOPE_LOW")) / 365 days
        );
        assertLe(comet.getSupplyRate(1e17), uint256(comet.getBorrowRate(1e17)) / 10 + 2);
    }

    function testForkRealDIAFeedNormalization() public view {
        assertEq(IPriceFeed(USDC_SOURCE).decimals(), 18);
        assertEq(IPriceFeed(LTC_SOURCE).decimals(), 18);
        (, int256 usdRaw,,,) = IPriceFeed(USDC_SOURCE).latestRoundData();
        (, int256 ltcRaw,,,) = IPriceFeed(LTC_SOURCE).latestRoundData();
        (, int256 usd,,,) = baseFeed.latestRoundData();
        (, int256 ltc,,,) = collateralFeed.latestRoundData();
        assertEq(usd, usdRaw / 1e10);
        assertEq(ltc, ltcRaw / 1e10);
        assertGt(usd, 0);
        assertGt(ltc, 0);
    }

    function testForkSupplyBorrowRepayAndWithdraw() public {
        uint256 lenderBefore = usdc.balanceOf(address(this));
        openPosition();
        assertEq(comet.borrowBalanceOf(BORROWER), 10e6);
        assertEq(usdc.balanceOf(BORROWER), 10e6);
        vm.startPrank(BORROWER);
        comet.supply(USDC, type(uint256).max);
        comet.withdraw(address(0), 1 ether);
        vm.stopPrank();
        comet.withdraw(USDC, type(uint256).max);
        assertEq(comet.borrowBalanceOf(BORROWER), 0);
        assertEq(ext.collateralBalanceOf(BORROWER, address(0)), 0);
        assertEq(BORROWER.balance, 1 ether);
        assertEq(usdc.balanceOf(address(this)), lenderBefore);
        assertEq(usdc.balanceOf(address(comet)), 0);
    }

    function testForkBridgeMintIsNotPublicFaucet() public {
        vm.expectRevert();
        usdc.bridgeMint(address(this), 1e6);
    }

    function testForkBaseDonationDoesNotMintShares() public {
        comet.supply(USDC, 100e6);
        uint256 claimsBefore = comet.balanceOf(address(this));
        usdc.transfer(address(comet), 50e6);
        assertEq(comet.balanceOf(address(this)), claimsBefore);
        assertEq(comet.getReserves(), int256(50e6));
    }

    function testForkActualBaseTokenSupplyAboveFormerCap() public {
        comet.supply(USDC, 1000e6 + 1);
        assertEq(usdc.balanceOf(address(comet)), 1000e6 + 1);
        assertEq(comet.totalSupply(), 1000e6 + 1);
    }

    function testForkStaleFeedBlocksBorrowButRepaymentWorks() public {
        openPosition();
        vm.warp(block.timestamp + 3 hours);
        vm.startPrank(BORROWER);
        vm.expectRevert(LithiumCometPriceFeed.InvalidPrice.selector);
        comet.withdraw(USDC, 1e6);
        comet.supply(USDC, 1e6);
        vm.stopPrank();
        assertLt(comet.borrowBalanceOf(BORROWER), 10e6);
    }
}
