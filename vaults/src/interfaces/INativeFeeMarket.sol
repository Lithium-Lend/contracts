// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.38;

import {INativeLendingMarket} from "./INativeLendingMarket.sol";

interface INativeFeeMarket is INativeLendingMarket {
    function userBasic(address account) external view returns (int104, uint64, uint64, uint16, uint8);
    function getUtilization() external view returns (uint256);
    function getSupplyRate(uint256 utilization) external view returns (uint64);
    function isTransferPaused() external view returns (bool);
    function transfer(address receiver, uint256 assets) external returns (bool);
}
