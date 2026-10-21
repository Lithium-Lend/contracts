// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.15;

import {RateRecalibrationFixture} from "./RateRecalibration.t.sol";
import {MockUSDC} from "./LithiumComet.t.sol";

interface ILithiumUSDC {
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
    function faucet() external returns (uint256);
    function nextFaucetAt(address) external view returns (uint256);
    function mint(address, uint256) external;
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

/// @dev Runs the real 0.8.30 token bytecode against the 0.8.15 Comet, not a mock ERC20.
/// Build first from contracts: forge build src/testnet/LithiumUSDC.sol
contract LithiumUSDCIntegrationTest is RateRecalibrationFixture {
    ILithiumUSDC internal token;
    uint256 internal constant CLAIM = 10_000e6;

    function setUp() public override {
        super.setUp();
        vm.setEvmVersion("shanghai");
        token = ILithiumUSDC(deployCode("../out/LithiumUSDC.sol/LithiumUSDC.json", abi.encode(address(this))));
        // Reuse the fixture's ERC20 signatures while executing the actual token bytecode.
        usdc = MockUSDC(address(token));
        config.baseToken = address(token);
        comet = newMarket(nonSubsidizedReference);
    }

    function supplyFromFaucet(address account, uint256 supplied) internal {
        vm.startPrank(account);
        assertEq(token.faucet(), CLAIM);
        token.approve(address(comet), supplied);
        comet.supply(address(token), supplied);
        vm.stopPrank();
    }

    function testFreshMarketUsesExactTokenAndSelectedRates() public view {
        assertEq(comet.baseToken(), address(token));
        assertEq(token.name(), "Lithium USDC");
        assertEq(token.symbol(), "lithUSDC");
        assertEq(token.decimals(), 6);
        assertEq(comet.borrowPerSecondInterestRateBase(), uint256(36e15) / 365 days);
        assertEq(comet.totalSupply(), 0);
        assertEq(comet.totalBorrow(), 0);
        assertEq(comet.getReserves(), 0);
    }

    function testClaimSupplyAndWithdrawFullTenThousand() public {
        supplyFromFaucet(alice, CLAIM);
        assertEq(comet.balanceOf(alice), CLAIM);
        assertEq(token.balanceOf(address(comet)), CLAIM);
        assertEq(token.balanceOf(alice), 0);
        vm.prank(alice);
        comet.withdraw(address(token), CLAIM);
        assertEq(token.balanceOf(alice), CLAIM);
        assertEq(comet.balanceOf(alice), 0);
    }

    function testBorrowRepayAndReturnNativeCollateral() public {
        supplyFromFaucet(alice, 100e6);
        uint256 beforeNative = bob.balance;
        vm.startPrank(bob);
        comet.supplyNative{value: 1 ether}();
        comet.withdraw(address(token), 50e6);
        assertEq(token.balanceOf(bob), 50e6);
        assertEq(comet.borrowBalanceOf(bob), 50e6);
        token.approve(address(comet), 50e6);
        comet.supply(address(token), 50e6);
        comet.withdraw(address(0), 1 ether);
        vm.stopPrank();
        assertEq(comet.borrowBalanceOf(bob), 0);
        assertEq(bob.balance, beforeNative);
        assertEq(token.balanceOf(address(comet)), 100e6);
    }

    function testMultipleWalletsCanSupplyFullFaucetAllocations() public {
        supplyFromFaucet(alice, CLAIM);
        supplyFromFaucet(bob, CLAIM);
        assertEq(token.balanceOf(bob), 0);
        assertEq(comet.totalSupply(), 2 * CLAIM);
        assertEq(token.balanceOf(address(comet)), 2 * CLAIM);
    }

    function testMintingToMarketFundsReservesNotUserSupply() public {
        token.mint(address(comet), 10e6);
        assertEq(comet.getReserves(), 10e6);
        assertEq(comet.totalSupply(), 0);
        assertEq(comet.balanceOf(address(this)), 0);
        assertEq(comet.totalBorrow(), 0);
    }

    function testClaimedTokensCanBuyLiquidatedNativeCollateral() public {
        supplyFromFaucet(alice, 100e6);
        vm.startPrank(bob);
        comet.supplyNative{value: 1 ether}();
        comet.withdraw(address(token), 60e6);
        vm.stopPrank();
        ltcSource.set(50e8);
        address[] memory accounts = new address[](1);
        accounts[0] = bob;
        comet.absorb(address(this), accounts);
        assertEq(comet.borrowBalanceOf(bob), 0);
        assertEq(comet.getCollateralReserves(address(0)), 1 ether);

        token.faucet();
        token.approve(address(comet), 47e6);
        uint256 nativeBefore = alice.balance;
        comet.buyCollateral(address(0), 1 ether, 47e6, alice);
        assertEq(alice.balance, nativeBefore + 1 ether);
        assertEq(comet.getCollateralReserves(address(0)), 0);
        assertEq(token.balanceOf(address(this)), CLAIM - 47e6);
    }

    function testSupplyWithdrawalDoesNotRefreshFaucetEligibility() public {
        supplyFromFaucet(alice, 100e6);
        uint256 next = token.nextFaucetAt(alice);
        vm.startPrank(alice);
        comet.withdraw(address(token), 100e6);
        vm.expectRevert(abi.encodeWithSignature("FaucetCooldownActive(uint256)", next));
        token.faucet();
        vm.stopPrank();
        assertEq(token.nextFaucetAt(alice), next);
    }
}
