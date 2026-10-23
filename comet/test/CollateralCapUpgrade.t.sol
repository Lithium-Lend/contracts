// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.15;

import {NativeBaseFixture} from "./LithiumNativeBaseComet.t.sol";
import {AdditionalMarketToken} from "./AdditionalMarketMocks.sol";
import {LithiumComet} from "../src/LithiumComet.sol";
import {LithiumNativeBaseComet} from "../src/LithiumNativeBaseComet.sol";
import {CometConfiguration} from "comet/CometConfiguration.sol";
import {CometMainInterface} from "comet/CometMainInterface.sol";
import {CometExtInterface} from "comet/CometExtInterface.sol";
import {ProxyAdmin} from "comet/vendor/proxy/transparent/ProxyAdmin.sol";
import {TransparentUpgradeableProxy} from "comet/vendor/proxy/transparent/TransparentUpgradeableProxy.sol";

/// @notice Cap-only upgrades must preserve all proxy storage and existing positions.
contract CollateralCapUpgradeTest is NativeBaseFixture {
    bytes32 internal constant IMPLEMENTATION_SLOT = bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);

    function testUSDCUpgradePreservesPositionsAndReopensCollateral() public {
        exercise(0, 1000 ether);
    }

    function testUSDTUpgradePreservesPositionsAndReopensCollateral() public {
        exercise(1, 1000 ether);
    }

    function testNativeBaseUpgradePreservesPositionsAndReopensCollateral() public {
        exercise(2, 1_000_000e6);
    }

    function testFuzzCapUpgradeWritesOnlyImplementationSlot(uint8 kind, uint64 increment) public {
        kind = uint8(bound(kind, 0, 2));
        uint128 oldCap = kind == 2 ? 1000e6 : 10 ether;
        uint128 unit = kind == 2 ? 1e6 : 1 ether;
        uint128 newCap = oldCap + uint128(bound(increment, 1, 1000)) * unit;
        exercise(kind, newCap);
    }

    function exercise(uint8 kind, uint128 newCap) internal {
        bool nativeBase = kind == 2;
        uint128 oldCap = nativeBase ? 1000e6 : 10 ether;
        uint256 borrowed = nativeBase ? 5 ether : 500e6;
        CometConfiguration.Configuration memory c = config;
        AdditionalMarketToken token = usdc;
        if (!nativeBase) {
            token = new AdditionalMarketToken(6);
            c.baseToken = address(token);
            c.baseTokenPriceFeed = config.assetConfigs[0].priceFeed;
            c.baseMinForRewards = 1e6;
            c.baseBorrowMin = 1e5;
            c.targetReserves = 100e6;
            c.assetConfigs[0] =
                CometConfiguration.AssetConfig(address(0), config.baseTokenPriceFeed, 18, 6e17, 7e17, 9e17, oldCap);
        } else {
            c.assetConfigs[0].supplyCap = oldCap;
        }
        string memory artifact = kind == 0
            ? "LithiumComet.sol:LithiumComet"
            : kind == 1 ? "LithiumUSDTComet.sol:LithiumUSDTComet" : "LithiumNativeBaseComet.sol:LithiumNativeBaseComet";
        ProxyAdmin admin = new ProxyAdmin(address(this));
        address implementation = deployCode(artifact, abi.encode(c));
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            implementation, address(admin), abi.encodeWithSignature("initializeStorage()")
        );
        CometMainInterface m = CometMainInterface(address(proxy));
        token.mint(address(this), 1_000_000e6);
        token.mint(alice, 1_000_000e6);
        token.mint(bob, 2_000_000e6);
        token.approve(address(m), type(uint256).max);
        vm.prank(alice);
        token.approve(address(m), type(uint256).max);
        vm.prank(bob);
        token.approve(address(m), type(uint256).max);
        vm.deal(bob, 10000 ether);
        if (kind == 1) token.configure(true, false, false, false);
        if (nativeBase) {
            LithiumNativeBaseComet(payable(address(m))).supplyNative{value: 100 ether}();
            LithiumNativeBaseComet(payable(address(m))).fundReservesNative{value: 10 ether}();
        } else {
            m.supply(address(token), 100_000e6);
            token.mint(address(m), 100e6);
        }
        deposit(m, nativeBase, address(token), alice, oldCap);
        vm.prank(alice);
        m.withdraw(c.baseToken, borrowed);
        vm.prank(alice);
        CometExtInterface(address(m)).allow(bob, true);
        bytes32 beforeState = state(m, address(token));
        vm.expectRevert(CometMainInterface.SupplyCapExceeded.selector);
        deposit(m, nativeBase, address(token), bob, 1);
        assertEq(state(m, address(token)), beforeState, "Failed deposit changed state");

        c.assetConfigs[0].supplyCap = newCap;
        address next = deployCode(artifact, abi.encode(c));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", alice));
        admin.upgrade(proxy, next);
        vm.record();
        admin.upgrade(proxy, next);
        (, bytes32[] memory writes) = vm.accesses(address(m));
        assertEq(writes.length, 1, "Upgrade must not write user or accounting storage");
        assertEq(writes[0], IMPLEMENTATION_SLOT);
        assertEq(state(m, address(token)), beforeState, "Upgrade changed balances, debt, or parameters");
        assertEq(m.getAssetInfo(0).supplyCap, newCap);
        assertEq(admin.getProxyImplementation(proxy), next);

        deposit(m, nativeBase, address(token), bob, newCap - oldCap);
        (uint128 total,) = m.totalsCollateral(c.assetConfigs[0].asset);
        assertEq(total, newCap);
        vm.expectRevert(CometMainInterface.SupplyCapExceeded.selector);
        deposit(m, nativeBase, address(token), bob, 1);
        vm.prank(bob);
        m.withdraw(c.assetConfigs[0].asset, newCap - oldCap);
        assertEq(m.borrowBalanceOf(alice), borrowed);
        vm.startPrank(alice);
        if (nativeBase) LithiumNativeBaseComet(payable(address(m))).supplyNative{value: borrowed}();
        else m.supply(address(token), type(uint256).max);
        assertEq(m.borrowBalanceOf(alice), 0);
        m.withdraw(c.assetConfigs[0].asset, oldCap);
        vm.stopPrank();
        (total,) = m.totalsCollateral(c.assetConfigs[0].asset);
        assertEq(total, 0, "Old and new collateral remain withdrawable");
    }

    function deposit(CometMainInterface m, bool nativeBase, address token, address account, uint256 amount) internal {
        vm.prank(account);
        if (nativeBase) m.supply(token, amount);
        else LithiumComet(payable(address(m))).supplyNative{value: amount}();
    }

    function state(CometMainInterface m, address token) internal view returns (bytes32) {
        CometExtInterface e = CometExtInterface(address(m));
        bytes32 result = keccak256(
            abi.encode(e.totalsBasic(), address(m).balance, AdditionalMarketToken(token).balanceOf(address(m)))
        );
        address collateralAsset = m.getAssetInfo(0).asset;
        for (uint256 i; i < 3; i++) {
            address account = i == 0 ? address(this) : i == 1 ? alice : bob;
            (int104 principal, uint64 index, uint64 accrued, uint16 assets, uint8 reserved) = m.userBasic(account);
            result = keccak256(
                abi.encode(
                    result,
                    principal,
                    index,
                    accrued,
                    assets,
                    reserved,
                    m.balanceOf(account),
                    m.borrowBalanceOf(account),
                    e.collateralBalanceOf(account, collateralAsset)
                )
            );
        }
        result = keccak256(
            abi.encode(
                result,
                m.totalSupply(),
                m.totalBorrow(),
                m.getReserves(),
                m.getCollateralReserves(collateralAsset),
                m.getUtilization(),
                m.isAllowed(alice, bob)
            )
        );
        for (uint256 i; i < 32; i++) {
            result = keccak256(abi.encode(result, vm.load(address(m), bytes32(i))));
        }
        return result;
    }
}
