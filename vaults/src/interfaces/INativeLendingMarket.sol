// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.30;

interface INativeLendingMarket {
    struct TotalsBasic {
        uint64 baseSupplyIndex;
        uint64 baseBorrowIndex;
        uint64 trackingSupplyIndex;
        uint64 trackingBorrowIndex;
        uint104 totalSupplyBase;
        uint104 totalBorrowBase;
        uint40 lastAccrualTime;
        uint8 pauseFlags;
    }

    function baseToken() external view returns (address);
    function baseScale() external view returns (uint256);
    function baseIndexScale() external view returns (uint64);
    function totalsBasic() external view returns (TotalsBasic memory);
    function balanceOf(address account) external view returns (uint256);
    function borrowBalanceOf(address account) external view returns (uint256);
    function accountedNative() external view returns (uint256);
    function getReserves() external view returns (int256);
    function isSupplyPaused() external view returns (bool);
    function isWithdrawPaused() external view returns (bool);
    function supplyNative() external payable;
    function withdraw(address asset, uint256 amount) external;
}
