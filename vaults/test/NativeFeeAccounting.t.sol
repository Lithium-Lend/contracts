// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {NativeLendingFeeVault} from "../src/NativeLendingFeeVault.sol";
import {INativeLendingMarket} from "../src/interfaces/INativeLendingMarket.sol";

contract AccountingMarketStub {
    address public constant baseToken = address(0);
    uint256 public constant baseScale = 1 ether;
    uint256 public constant baseIndexScale = 1e15;
    bool public constant isSupplyPaused = false;
    uint64 private index = 1e15;
    mapping(address => int104) private principals;

    function setBook(address owner, uint64 newIndex, int104 principal) external {
        index = newIndex;
        principals[owner] = principal;
    }

    function totalsBasic() external view returns (INativeLendingMarket.TotalsBasic memory totals) {
        totals.baseSupplyIndex = index;
        totals.lastAccrualTime = uint40(block.timestamp);
    }

    function userBasic(address owner) external view returns (int104, uint64, uint64, uint16, uint8) {
        return (principals[owner], 0, 0, 0, 0);
    }

    function balanceOf(address owner) external view returns (uint256) {
        return uint256(uint104(principals[owner])) * index / 1e15;
    }

    function getUtilization() external pure returns (uint256) {
        return 0;
    }

    function getSupplyRate(uint256) external pure returns (uint64) {
        return 0;
    }

    function getReserves() external pure returns (int256) {
        return 1 ether;
    }

    function borrowBalanceOf(address) external pure returns (uint256) {
        return 0;
    }

    function supplyNative() external payable {
        principals[msg.sender] += int104(uint104(msg.value * 1e15 / index));
    }
}

contract NativeFeeAccountingTest is Test {
    NativeLendingFeeVault private vault;
    AccountingMarketStub private market;
    address private holder;

    function setUp() public {
        market = new AccountingMarketStub();
        holder = makeAddr("holder");
        vault = new NativeLendingFeeVault(address(market), address(this), makeAddr("treasury"), 10_000 ether, "V", "V");
        vm.deal(holder, 10 ether);
        vm.prank(holder);
        vault.deposit{value: 10 ether}(10 ether, holder);
    }

    function testRoundingReconciliation() public {
        int104 principal = int104(10 ether - 37);
        market.setBook(address(vault), 1e15, principal);
        assertEq(vault.accrueFees(), 0);
        assertFalse(vault.recoveryMode());
        assertEq(vault.roundingLossCarry(), 37);
        assertEq(vault.accrueFees(), 0);
        assertEq(vault.roundingLossCarry(), 37);
        market.setBook(address(vault), 1e15 + 1, principal);
        uint256 quoted = vault.pendingFeeShares();
        assertGt(quoted, 0);
        assertEq(vault.accrueFees(), quoted);
        assertEq(vault.roundingLossCarry(), 0);
        assertEq(vault.feeNumeratorCarry(), (vault.totalAssets() - 10 ether) * 1000 % 10_000);
    }

    function testMaterialBookLossStopsDepositsAndFees() public {
        market.setBook(address(vault), 1e15, int104(9 ether));
        assertEq(vault.maxDeposit(holder), 0);
        assertEq(vault.accrueFees(), 0);
        assertTrue(vault.recoveryMode());
    }
}
