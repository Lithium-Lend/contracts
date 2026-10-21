// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.15;

import {NativeBaseFixture} from "./LithiumNativeBaseComet.t.sol";
import {AdditionalMarketToken} from "./AdditionalMarketMocks.sol";
import {CometWithExtendedAssetList} from "comet/CometWithExtendedAssetList.sol";
import {CometExtAssetList} from "comet/CometExtAssetList.sol";
import {AssetListFactory} from "comet/AssetListFactory.sol";
import {CometConfiguration} from "comet/CometConfiguration.sol";
import {TransparentUpgradeableProxy} from "comet/vendor/proxy/transparent/TransparentUpgradeableProxy.sol";

/// @dev Compare accounting to the pinned upstream using an 18-decimal ERC-20
/// base double only in tests. The production zkLTC market never uses a wrapper.
contract LithiumNativeBaseDifferentialTest is NativeBaseFixture {
    CometWithExtendedAssetList internal referenceMarket;
    AdditionalMarketToken internal referenceBase;

    function setUp() public override {
        super.setUp();
        referenceBase = new AdditionalMarketToken(18);
        CometConfiguration.Configuration memory c = config;
        c.baseToken = address(referenceBase);
        c.extensionDelegate = address(
            new CometExtAssetList(
                CometConfiguration.ExtConfiguration(bytes32("Reference"), bytes32("ref")),
                address(new AssetListFactory())
            )
        );
        address implementation = deployCode("CometWithExtendedAssetList.sol:CometWithExtendedAssetList", abi.encode(c));
        referenceMarket = CometWithExtendedAssetList(
            payable(address(
                    new TransparentUpgradeableProxy(
                        implementation, proxyAdmin, abi.encodeWithSignature("initializeStorage()")
                    )
                ))
        );
        referenceBase.mint(address(this), 110 ether);
        referenceBase.approve(address(referenceMarket), type(uint256).max);
        referenceMarket.supply(address(referenceBase), 100 ether);
        referenceBase.transfer(address(referenceMarket), 10 ether);
        vm.prank(alice);
        usdc.approve(address(referenceMarket), type(uint256).max);
    }

    function testFuzzInterestRepaymentAndLiquidationMatchUpstream(uint96 seed, uint32 elapsed) public {
        uint256 amount = bound(uint256(seed), 0.01 ether, 5 ether);
        collateral(1000e6);
        vm.prank(alice);
        referenceMarket.supply(address(usdc), 1000e6);
        borrow(amount);
        vm.prank(alice);
        referenceMarket.withdraw(address(referenceBase), amount);
        compare();
        vm.warp(block.timestamp + bound(uint256(elapsed), 1, 365 days));
        refresh();
        market.accrueAccount(alice);
        referenceMarket.accrueAccount(alice);
        compare();
        ltcSource.set(170e8);
        assertEq(market.isLiquidatable(alice), referenceMarket.isLiquidatable(alice));
        assertEq(market.isBorrowCollateralized(alice), referenceMarket.isBorrowCollateralized(alice));
        if (market.isLiquidatable(alice)) {
            absorbAlice();
            address[] memory accounts = new address[](1);
            accounts[0] = alice;
            referenceMarket.absorb(bob, accounts);
            compare();
            uint256 quote = market.quoteCollateral(address(usdc), 1 ether);
            assertEq(quote, referenceMarket.quoteCollateral(address(usdc), 1 ether));
            market.buyCollateralNative{value: 1 ether}(address(usdc), quote, bob);
            referenceBase.mint(address(this), 1 ether);
            referenceMarket.buyCollateral(address(usdc), quote, 1 ether, bob);
        } else {
            uint256 debt = market.borrowBalanceOf(alice);
            market.supplyNativeTo{value: debt}(alice);
            referenceBase.mint(address(this), debt);
            referenceMarket.supplyTo(alice, address(referenceBase), debt);
        }
        compare();
    }

    function compare() internal view {
        assertEq(market.balanceOf(address(this)), referenceMarket.balanceOf(address(this)));
        assertEq(market.balanceOf(alice), referenceMarket.balanceOf(alice));
        assertEq(market.borrowBalanceOf(alice), referenceMarket.borrowBalanceOf(alice));
        assertEq(market.totalSupply(), referenceMarket.totalSupply());
        assertEq(market.totalBorrow(), referenceMarket.totalBorrow());
        assertEq(market.getReserves(), referenceMarket.getReserves());
        assertEq(market.getCollateralReserves(address(usdc)), referenceMarket.getCollateralReserves(address(usdc)));
        assertEq(market.accountedNative(), referenceBase.balanceOf(address(referenceMarket)));
        assertEq(market.getUtilization(), referenceMarket.getUtilization());
    }
}
