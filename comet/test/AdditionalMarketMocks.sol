// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.15;

/// @dev Test-only ERC-20 double, including USDT-style missing return data and zero-reset approvals.
contract AdditionalMarketToken {
    uint8 public immutable decimals;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    bool public noReturn;
    bool public returnsFalse;
    bool public tax;
    bool public paused;
    address public callbackTarget;
    bytes public callbackData;
    bool public callbackSucceeded;
    bytes public callbackResult;

    constructor(uint8 decimals_) {
        decimals = decimals_;
    }

    function configure(bool noReturn_, bool returnsFalse_, bool tax_, bool paused_) external {
        noReturn = noReturn_;
        returnsFalse = returnsFalse_;
        tax = tax_;
        paused = paused_;
    }

    function setCallback(address target, bytes calldata data) external {
        callbackTarget = target;
        callbackData = data;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address to, uint256 amount) external returns (bool) {
        require(amount == 0 || allowance[msg.sender][to] == 0, "Reset allowance first");
        allowance[msg.sender][to] = amount;
        return respond();
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        move(msg.sender, to, amount);
        return respond();
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (allowance[from][msg.sender] != type(uint256).max) allowance[from][msg.sender] -= amount;
        move(from, to, amount);
        return respond();
    }

    function move(address from, address to, uint256 amount) internal {
        require(!paused, "Token paused");
        balanceOf[from] -= amount;
        balanceOf[to] += tax ? amount * 99 / 100 : amount;
        if (callbackTarget != address(0)) {
            (callbackSucceeded, callbackResult) = callbackTarget.call(callbackData);
        }
    }

    function respond() internal view returns (bool) {
        if (noReturn) {
            assembly ("memory-safe") {
                return(0, 0)
            }
        }
        return !returnsFalse;
    }
}
