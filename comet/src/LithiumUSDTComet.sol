// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.15;

import {LithiumComet} from "./LithiumComet.sol";

/// @notice Separate six-decimal USDT-base market with native zkLTC collateral.
/// @dev Reuses the frozen stablecoin-base implementation without upgrading an existing market.
///      The deployment must identify and validate the actual transfer-preserving USDT token.
contract LithiumUSDTComet is LithiumComet {
    constructor(Configuration memory config) LithiumComet(config) {}
}
