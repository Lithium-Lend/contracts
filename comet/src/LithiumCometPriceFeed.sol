// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.15;

import {IPriceFeed} from "comet/interfaces/IPriceFeed.sol";

/// @notice Freshness-checked, eight-decimal USD price for a Comet asset.
contract LithiumCometPriceFeed is IPriceFeed {
    IPriceFeed public immutable source;
    uint256 public immutable maxStaleness;
    uint8 public immutable sourceDecimals;

    error InvalidFeed();
    error InvalidPrice();

    constructor(address source_, uint256 maxStaleness_) {
        if (source_.code.length == 0 || maxStaleness_ == 0 || IPriceFeed(source_).decimals() > 36) {
            revert InvalidFeed();
        }
        source = IPriceFeed(source_);
        maxStaleness = maxStaleness_;
        sourceDecimals = IPriceFeed(source_).decimals();
    }

    function decimals() external pure override returns (uint8) {
        return 8;
    }

    function description() external view override returns (string memory) {
        return source.description();
    }

    function version() external pure override returns (uint256) {
        return 1;
    }

    function latestRoundData()
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        (roundId, answer, startedAt, updatedAt, answeredInRound) = source.latestRoundData();
        if (
            answer <= 0 || updatedAt == 0 || updatedAt > block.timestamp || block.timestamp - updatedAt > maxStaleness
                || answeredInRound < roundId
        ) revert InvalidPrice();
        if (sourceDecimals > 8) {
            answer /= int256(10 ** uint256(sourceDecimals - 8));
        } else if (sourceDecimals < 8) {
            int256 scale = int256(10 ** uint256(8 - sourceDecimals));
            if (answer > type(int256).max / scale) revert InvalidPrice();
            answer *= scale;
        }
        if (answer == 0) revert InvalidPrice();
    }
}
