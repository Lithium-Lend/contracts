// SPDX-License-Identifier: LicenseRef-Lithium-Proprietary
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @notice Lithium's mintable USDT substitute for LiteForge testing, not Tether-issued USDT.
/// @dev The token and faucet share one contract. No fees, rebasing, callbacks or proxy.
contract LithiumUSDT is ERC20, Ownable2Step {
    uint256 public constant CHAIN_ID = 4441;
    uint256 public constant faucetAmount = 10_000e6;
    uint256 public constant faucetCooldown = 1 days;

    mapping(address account => uint256 timestamp) public nextFaucetAt;

    error LiteForgeOnly(uint256 actualChainId);
    error FaucetCooldownActive(uint256 availableAt);

    event FaucetClaimed(address indexed account, uint256 amount, uint256 nextClaimAt);

    constructor(address owner_) ERC20("Lithium USDT", "lithUSDT") Ownable(owner_) {
        _requireLiteForge();
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /// @notice Mint a fixed allocation to the caller, at most once per rolling 24 hours.
    /// @dev Limits claims per address, not per person. No external calls or approvals.
    function faucet() external returns (uint256 amount) {
        _requireLiteForge();
        uint256 availableAt = nextFaucetAt[msg.sender];
        if (block.timestamp < availableAt) revert FaucetCooldownActive(availableAt);

        uint256 nextClaimAt = block.timestamp + faucetCooldown;
        nextFaucetAt[msg.sender] = nextClaimAt;
        amount = faucetAmount;
        _mint(msg.sender, amount);
        emit FaucetClaimed(msg.sender, amount, nextClaimAt);
    }

    /// @notice Owner minting for test allocations and liquidity. Does not supply into a market.
    function mint(address to, uint256 amount) external onlyOwner {
        _requireLiteForge();
        _mint(to, amount);
    }

    function _requireLiteForge() private view {
        if (block.chainid != CHAIN_ID) revert LiteForgeOnly(block.chainid);
    }
}
