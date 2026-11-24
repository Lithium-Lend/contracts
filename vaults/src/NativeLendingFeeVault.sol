// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.38;

import {ERC20} from "@openzeppelin/token/ERC20/ERC20.sol";
import {Math} from "@openzeppelin/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/utils/ReentrancyGuard.sol";
import {INativeLendingMarket} from "./interfaces/INativeLendingMarket.sol";
import {INativeFeeMarket} from "./interfaces/INativeFeeMarket.sol";

/// @notice Fixed-market native lending shares with an immutable earnings fee.
/// @dev Comet balance donations enter share value. Unsolicited native funds are excluded.
contract NativeLendingFeeVault is ERC20, ReentrancyGuard {
    using Math for uint256;

    address public constant NATIVE_ASSET = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    uint256 public constant VIRTUAL_SHARES = 1_000_000;
    // One more than the largest principal rounding loss representable by Comet's uint64 index.
    uint256 private constant MIN_ENTRY_CAPACITY = (uint256(type(uint64).max) + 1e15 - 1) / 1e15 + 1;
    INativeFeeMarket public immutable market;
    uint256 public constant PERFORMANCE_FEE_BPS = 1000;
    uint256 private constant BPS = 10_000;
    uint256 private constant MAX_EXTERNAL_ROUNDING = 1 gwei;
    address public immutable feeRecipient;
    bool public recoveryMode;
    uint256 public trackedPrincipal;
    uint256 public checkpointIndex;
    uint256 public roundingLossCarry;
    // Native base units multiplied by BPS. Keeps fractions across permissionless checkpoints.
    uint256 public feeNumeratorCarry;

    struct Accounting {
        uint256 assets;
        uint256 principal;
        uint256 index;
        bool healthy;
    }

    event FeesAccrued(uint256 earnings, uint256 feeAssets, uint256 feeShares);
    event RecoveryActivated(address indexed caller);
    event ClaimRedeemed(
        address indexed caller, address indexed owner, address indexed receiver, uint256 shares, uint256 claim
    );
    error RecoveryRequired();
    error ClaimTransferFailed();
    address public immutable guardian;
    uint256 public immutable depositCap;
    bool public isShutdown;
    bool private snapshotActive;
    uint256 private snapshotAssets;
    uint256 private expectedNative;

    error InvalidConfiguration();
    error InvalidReceiver();
    error InvalidAmount();
    error EntryUnavailable();
    error InsufficientLiquidity();
    error Slippage();
    error SupplyRateBelowMinimum(uint64 actual, uint64 minimum);
    error DeadlineExpired();
    error UnexpectedNative();
    error NativeTransferFailed();
    error UnexpectedDebt();
    error NoMarketCredit();
    error UnexpectedMarketLoss();
    error Unauthorized();

    event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares);
    event Withdraw(
        address indexed sender, address indexed receiver, address indexed owner, uint256 assets, uint256 shares
    );
    event Shutdown(address indexed guardian);

    constructor(
        address market_,
        address guardian_,
        address feeRecipient_,
        uint256 cap_,
        string memory name_,
        string memory symbol_
    ) ERC20(name_, symbol_) {
        if (market_.code.length == 0 || guardian_ == address(0) || cap_ == 0 || cap_ > uint104(type(int104).max)) {
            revert InvalidConfiguration();
        }
        market = INativeFeeMarket(market_);
        if (market.baseToken() != address(0) || market.baseScale() != 1 ether || market.baseIndexScale() != 1e15) {
            revert InvalidConfiguration();
        }
        guardian = guardian_;
        depositCap = cap_;
        if (feeRecipient_ == address(0) || feeRecipient_ == address(this) || feeRecipient_ == market_) {
            revert InvalidConfiguration();
        }
        feeRecipient = feeRecipient_;
        Accounting memory state = accounting();
        if (!state.healthy) revert InvalidConfiguration();
        trackedPrincipal = state.principal;
        checkpointIndex = state.index;
    }

    /// @notice Reconstructs the accrued index using the pinned native Comet arithmetic.
    /// @dev Reverts on unavailable or inconsistent market data; never substitutes a zero price.
    function accounting() public view returns (Accounting memory state) {
        INativeLendingMarket.TotalsBasic memory totals = market.totalsBasic();
        if (totals.baseSupplyIndex < 1e15 || totals.lastAccrualTime > block.timestamp) revert InvalidConfiguration();
        uint256 rate = market.getSupplyRate(market.getUtilization());
        state.index = uint256(totals.baseSupplyIndex) + uint256(totals.baseSupplyIndex)
            * (rate * (block.timestamp - totals.lastAccrualTime)) / 1e18;
        if (state.index > type(uint64).max) revert InvalidConfiguration();
        (int104 principal,,,,) = market.userBasic(address(this));
        state.principal = principal > 0 ? uint104(principal) : 0;
        state.assets = market.balanceOf(address(this));
        if (state.assets != state.principal * state.index / 1e15) revert InvalidConfiguration();
        uint256 expectedAssets = trackedPrincipal * state.index / 1e15;
        state.healthy = principal >= 0 && market.borrowBalanceOf(address(this)) == 0 && market.getReserves() >= 0
            && state.index >= checkpointIndex && state.assets + MAX_EXTERNAL_ROUNDING >= expectedAssets
            && (state.assets != 0 || totalSupply() == 0);
    }

    function _healthy() private view returns (bool) {
        if (recoveryMode) return false;
        try this.accounting() returns (Accounting memory state) {
            return state.healthy;
        } catch {
            return false;
        }
    }

    /// @notice Fee shares included in conversion quotes but not yet minted.
    function pendingFeeShares() public view returns (uint256 shares) {
        if (recoveryMode || snapshotActive || totalSupply() == 0) return 0;
        Accounting memory state = accounting();
        if (!state.healthy) return 0;
        (shares,,,,) = _fees(state);
    }

    function _effectiveSupply() private view returns (uint256) {
        return totalSupply() + pendingFeeShares();
    }

    function _fees(Accounting memory state)
        private
        view
        returns (uint256 shares, uint256 assets, uint256 remainder, uint256 loss, uint256 earnings)
    {
        if (totalSupply() == 0) return (0, 0, 0, 0, 0);
        // Ignore donated principal and charge only on net growth after observed rounding losses.
        uint256 openingAssets = trackedPrincipal * checkpointIndex / 1e15;
        uint256 closingAssets = Math.min(trackedPrincipal, state.principal) * state.index / 1e15;
        loss = roundingLossCarry;
        if (closingAssets < openingAssets) {
            loss += openingAssets - closingAssets;
        } else {
            uint256 growth = closingAssets - openingAssets;
            uint256 recovered = Math.min(growth, loss);
            loss -= recovered;
            earnings = growth - recovered;
        }
        remainder = feeNumeratorCarry + earnings * PERFORMANCE_FEE_BPS;
        assets = remainder / BPS;
        if (assets != 0) {
            if (assets > state.assets) revert UnexpectedMarketLoss();
            shares = assets.mulDiv(totalSupply() + VIRTUAL_SHARES, state.assets + 1 - assets);
            // If less than one share is payable, retain the entire fee for a later checkpoint.
            if (shares != 0) remainder -= assets * BPS;
            else assets = 0;
        }
    }

    /// @notice Collect eligible interest fees or permanently enter recovery on observed impairment.
    function accrueFees() external nonReentrant returns (uint256 shares) {
        if (recoveryMode) return 0;
        Accounting memory state = accounting();
        if (!state.healthy) {
            _activateRecovery();
            return 0;
        }
        return _applyFees(state);
    }

    function _settleFees() private {
        if (recoveryMode) revert RecoveryRequired();
        Accounting memory state = accounting();
        if (!state.healthy) revert RecoveryRequired();
        _applyFees(state);
    }

    function _applyFees(Accounting memory state) private returns (uint256 shares) {
        uint256 assets;
        uint256 earnings;
        (shares, assets, feeNumeratorCarry, roundingLossCarry, earnings) = _fees(state);
        trackedPrincipal = state.principal;
        checkpointIndex = state.index;
        if (shares != 0) _mint(feeRecipient, shares);
        emit FeesAccrued(earnings, assets, shares);
    }

    function _checkpoint(uint256 expected, uint256 actual) private {
        if (actual < expected) roundingLossCarry += expected - actual;
        Accounting memory state = accounting();
        if (state.index != checkpointIndex || market.getReserves() < 0) revert UnexpectedMarketLoss();
        trackedPrincipal = state.principal;
        checkpointIndex = state.index;
    }

    /// @notice Terminal mode. The guardian can activate it; anyone can report observed impairment.
    function activateRecovery() external nonReentrant {
        if (msg.sender != guardian && accounting().healthy) revert Unauthorized();
        if (!recoveryMode) _activateRecovery();
    }

    function _activateRecovery() private {
        recoveryMode = true;
        isShutdown = true;
        feeNumeratorCarry = 0;
        roundingLossCarry = 0;
        emit RecoveryActivated(msg.sender);
    }

    /// @notice Book claim distributed in recovery. This is not a native cash redemption quote.
    function previewRedeemClaim(uint256 shares) public view returns (uint256) {
        // Keep the virtual claim intact in every exit mode, including terminal recovery.
        return shares.mulDiv(totalAssets() + 1, totalSupply() + VIRTUAL_SHARES);
    }

    function maxRedeemClaim(address owner) external view returns (uint256) {
        if (!recoveryMode || snapshotActive) return 0;
        try market.isTransferPaused() returns (bool paused) {
            if (paused) return 0;
        } catch {
            return 0;
        }
        try market.borrowBalanceOf(address(this)) returns (uint256 debt) {
            if (debt != 0) return 0;
        } catch {
            return 0;
        }
        try market.balanceOf(address(this)) returns (uint256 claim) {
            uint256 shares = balanceOf(owner);
            uint256 supply = totalSupply();
            if (claim == 0 || shares == 0 || supply == 0) return 0;
            // Comet can round a very small receipt transfer to zero at the receiver.
            try this.accounting() returns (Accounting memory state) {
                return shares.mulDiv(claim + 1, supply + VIRTUAL_SHARES) > Math.ceilDiv(state.index, 1e15) ? shares : 0;
            } catch {
                return 0;
            }
        } catch {
            return 0;
        }
    }

    /// @notice Burns shares for market receipt claims, subject to the market's transfer restrictions.
    /// @dev A receiver with market debt is rejected so the receipt cannot silently repay that debt.
    function redeemClaim(uint256 shares, address receiver, address owner, uint256 minClaim, uint256 deadline)
        external
        nonReentrant
        returns (uint256 received)
    {
        _deadline(deadline);
        _receiver(receiver);
        if (!recoveryMode) revert RecoveryRequired();
        if (shares == 0 || shares > balanceOf(owner)) revert InvalidAmount();
        _noDebt();
        if (market.borrowBalanceOf(receiver) != 0) revert UnexpectedDebt();
        if (msg.sender != owner) _spendAllowance(owner, msg.sender, shares);
        uint256 claim = previewRedeemClaim(shares);
        if (claim == 0) revert InvalidAmount();
        uint256 beforeReceiver = market.balanceOf(receiver);
        snapshotAssets = market.balanceOf(address(this));
        snapshotActive = true;
        if (!market.transfer(receiver, claim)) revert ClaimTransferFailed();
        _noDebt();
        _checkMarketLoss(snapshotAssets - claim, market.balanceOf(address(this)));
        received = market.balanceOf(receiver) - beforeReceiver;
        if (received == 0 || received < minClaim) revert Slippage();
        _burn(owner, shares);
        snapshotActive = false;
        emit ClaimRedeemed(msg.sender, owner, receiver, shares, received);
    }

    function decimals() public pure override returns (uint8) {
        return 24;
    }

    function asset() external pure returns (address) {
        return NATIVE_ASSET;
    }

    /// @notice Accrued book claim in native base units. This is not a cash guarantee.
    function totalAssets() public view returns (uint256) {
        return snapshotActive ? snapshotAssets : market.balanceOf(address(this));
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        return assets.mulDiv(_effectiveSupply() + VIRTUAL_SHARES, totalAssets() + 1, Math.Rounding.Floor);
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        return shares.mulDiv(totalAssets() + 1, _effectiveSupply() + VIRTUAL_SHARES, Math.Rounding.Floor);
    }

    function previewDeposit(uint256 assets) public view returns (uint256) {
        return convertToShares(assets);
    }

    function previewRedeem(uint256 shares) public view returns (uint256) {
        return convertToAssets(shares);
    }

    function previewMint(uint256 shares) public view returns (uint256) {
        return shares.mulDiv(totalAssets() + 1, _effectiveSupply() + VIRTUAL_SHARES, Math.Rounding.Ceil);
    }

    function previewWithdraw(uint256 assets) public view returns (uint256) {
        return assets.mulDiv(_effectiveSupply() + VIRTUAL_SHARES, totalAssets() + 1, Math.Rounding.Ceil);
    }

    function maxDeposit(address receiver) public view returns (uint256) {
        if (
            receiver == address(0) || receiver == address(this) || receiver == address(market) || isShutdown
                || snapshotActive || !_healthy()
        ) return 0;
        try market.isSupplyPaused() returns (bool paused) {
            if (paused) return 0;
        } catch {
            return 0;
        }
        try market.borrowBalanceOf(address(this)) returns (uint256 debt) {
            if (debt != 0) return 0;
        } catch {
            return 0;
        }
        try market.getReserves() returns (int256 reserves) {
            if (reserves < 0) return 0;
        } catch {
            return 0;
        }
        try market.balanceOf(address(this)) returns (uint256 assets) {
            if (assets == 0 && totalSupply() != 0) return 0;
            if (assets >= depositCap) return 0;
            try market.totalsBasic() returns (INativeLendingMarket.TotalsBasic memory totals) {
                if (totals.baseSupplyIndex < 1e15) return 0;
                // The stored index is no greater than the accrued index, so this underestimates capacity.
                uint256 marketCapacity =
                    uint256(type(uint104).max - totals.totalSupplyBase) * totals.baseSupplyIndex / 1e15;
                uint256 capacity = Math.min(depositCap - assets, marketCapacity);
                if (capacity < MIN_ENTRY_CAPACITY) return 0;
                return capacity.mulDiv(_effectiveSupply() + VIRTUAL_SHARES, assets + 1) == 0 ? 0 : capacity;
            } catch {
                return 0;
            }
        } catch {
            return 0;
        }
    }

    function maxMint(address receiver) public view returns (uint256) {
        uint256 capacity = maxDeposit(receiver);
        if (capacity == 0) return 0;
        uint256 shares = convertToShares(capacity);
        return previewMint(shares) < MIN_ENTRY_CAPACITY ? 0 : shares;
    }

    function liquidAssets() public view returns (uint256) {
        if (snapshotActive || !_healthy()) return 0;
        try market.totalsBasic() returns (INativeLendingMarket.TotalsBasic memory totals) {
            if (totals.baseSupplyIndex < 1e15) return 0;
        } catch {
            return 0;
        }
        try market.isWithdrawPaused() returns (bool paused) {
            if (paused) return 0;
        } catch {
            return 0;
        }
        try market.borrowBalanceOf(address(this)) returns (uint256 debt) {
            if (debt != 0) return 0;
        } catch {
            return 0;
        }
        try market.balanceOf(address(this)) returns (uint256 claim) {
            try market.accountedNative() returns (uint256 cash) {
                return Math.min(claim, cash);
            } catch {
                return 0;
            }
        } catch {
            return 0;
        }
    }

    function maxWithdraw(address owner) public view returns (uint256) {
        uint256 liquidity = liquidAssets();
        return liquidity == 0 ? 0 : Math.min(convertToAssets(balanceOf(owner)), liquidity);
    }

    function maxRedeem(address owner) public view returns (uint256) {
        uint256 liquidity = liquidAssets();
        if (liquidity == 0) return 0;
        uint256 shares = Math.min(balanceOf(owner), convertToShares(liquidity));
        return convertToAssets(shares) == 0 ? 0 : shares;
    }

    /// @dev The funded amount is msg.value. assets must match it to reject ambiguous calls.
    function deposit(uint256 assets, address receiver) external payable nonReentrant returns (uint256 shares) {
        return _deposit(assets, receiver, 0);
    }

    function depositWithMinShares(uint256 assets, address receiver, uint256 minShares, uint256 deadline)
        external
        payable
        nonReentrant
        returns (uint256 shares)
    {
        _deadline(deadline);
        return _deposit(assets, receiver, minShares);
    }

    /// @notice Supply only when the market's gross per-second rate after this deposit meets the floor.
    /// @dev The rate uses the market's 1e18 scale and may change after the transaction.
    function depositWithMinSupplyRate(
        uint256 assets,
        address receiver,
        uint256 minShares,
        uint64 minRate,
        uint256 deadline
    ) external payable nonReentrant returns (uint256 shares, uint64 rate) {
        _deadline(deadline);
        shares = _deposit(assets, receiver, minShares);
        rate = market.getSupplyRate(market.getUtilization());
        if (rate < minRate) revert SupplyRateBelowMinimum(rate, minRate);
    }

    function _deposit(uint256 assets, address receiver, uint256 minShares) private returns (uint256 shares) {
        _receiver(receiver);
        if (assets == 0 || assets != msg.value) revert InvalidAmount();
        _settleFees();
        if (assets > maxDeposit(receiver)) revert EntryUnavailable();
        shares = previewDeposit(assets);
        if (shares == 0 || shares < minShares) revert Slippage();
        _supply(assets);
        _mint(receiver, shares);
        snapshotActive = false;
        emit Deposit(msg.sender, receiver, assets, shares);
    }

    /// @dev Excess native value is returned to the payer after shares and market assets are updated.
    function mint(uint256 shares, address receiver) external payable nonReentrant returns (uint256 assets) {
        return _mintExact(shares, receiver, type(uint256).max);
    }

    function mintWithMaxAssets(uint256 shares, address receiver, uint256 maxAssets, uint256 deadline)
        external
        payable
        nonReentrant
        returns (uint256 assets)
    {
        _deadline(deadline);
        return _mintExact(shares, receiver, maxAssets);
    }

    function _mintExact(uint256 shares, address receiver, uint256 maxAssets) private returns (uint256 assets) {
        _receiver(receiver);
        if (shares == 0) revert InvalidAmount();
        _settleFees();
        assets = previewMint(shares);
        if (assets > maxAssets) revert Slippage();
        if (assets == 0 || msg.value < assets) revert InvalidAmount();
        if (assets > maxDeposit(receiver)) revert EntryUnavailable();
        _supply(assets);
        _mint(receiver, shares);
        snapshotActive = false;
        emit Deposit(msg.sender, receiver, assets, shares);
        if (msg.value > assets) _send(msg.sender, msg.value - assets);
    }

    function _supply(uint256 assets) private {
        snapshotAssets = market.balanceOf(address(this));
        snapshotActive = true;
        market.supplyNative{value: assets}();
        _noDebt();
        uint256 credited = market.balanceOf(address(this));
        if (credited <= snapshotAssets) revert NoMarketCredit();
        _checkMarketLoss(snapshotAssets + assets, credited);
        _checkpoint(snapshotAssets + assets, credited);
    }

    function withdraw(uint256 assets, address receiver, address owner) external nonReentrant returns (uint256 shares) {
        return _withdraw(assets, receiver, owner, type(uint256).max);
    }

    function withdrawWithMaxShares(uint256 assets, address receiver, address owner, uint256 maxShares, uint256 deadline)
        external
        nonReentrant
        returns (uint256 shares)
    {
        _deadline(deadline);
        return _withdraw(assets, receiver, owner, maxShares);
    }

    function _withdraw(uint256 assets, address receiver, address owner, uint256 maxShares)
        private
        returns (uint256 shares)
    {
        if (assets == 0) revert InvalidAmount();
        _settleFees();
        if (assets > maxWithdraw(owner)) revert InsufficientLiquidity();
        shares = previewWithdraw(assets);
        if (shares > maxShares) revert Slippage();
        _exit(assets, shares, receiver, owner);
    }

    function redeem(uint256 shares, address receiver, address owner) external nonReentrant returns (uint256 assets) {
        return _redeem(shares, receiver, owner, 0);
    }

    function redeemWithMinAssets(uint256 shares, address receiver, address owner, uint256 minAssets, uint256 deadline)
        external
        nonReentrant
        returns (uint256 assets)
    {
        _deadline(deadline);
        return _redeem(shares, receiver, owner, minAssets);
    }

    function _redeem(uint256 shares, address receiver, address owner, uint256 minAssets)
        private
        returns (uint256 assets)
    {
        if (shares == 0) revert InvalidAmount();
        _settleFees();
        if (shares > balanceOf(owner)) revert InsufficientLiquidity();
        assets = previewRedeem(shares);
        if (assets == 0 || assets < minAssets) revert Slippage();
        if (assets > liquidAssets()) revert InsufficientLiquidity();
        _exit(assets, shares, receiver, owner);
    }

    function _exit(uint256 assets, uint256 shares, address receiver, address owner) private {
        _receiver(receiver);
        if (msg.sender != owner) _spendAllowance(owner, msg.sender, shares);
        snapshotAssets = market.balanceOf(address(this));
        snapshotActive = true;
        expectedNative = assets;
        market.withdraw(address(0), assets);
        if (expectedNative != 0) revert UnexpectedNative();
        _noDebt();
        _checkMarketLoss(snapshotAssets - assets, market.balanceOf(address(this)));
        _checkpoint(snapshotAssets - assets, market.balanceOf(address(this)));
        _burn(owner, shares);
        if (totalSupply() == 0) {
            feeNumeratorCarry = 0;
            roundingLossCarry = 0;
        }
        snapshotActive = false;
        emit Withdraw(msg.sender, receiver, owner, assets, shares);
        _send(receiver, assets);
    }

    function shutdown() external nonReentrant {
        if (msg.sender != guardian) revert Unauthorized();
        isShutdown = true;
        emit Shutdown(msg.sender);
    }

    function _noDebt() private view {
        if (market.borrowBalanceOf(address(this)) != 0) revert UnexpectedDebt();
    }

    function _receiver(address receiver) private view {
        if (receiver == address(0) || receiver == address(this) || receiver == address(market)) {
            revert InvalidReceiver();
        }
    }

    /// @dev Comet floors supply principal and its present value. One principal unit bounds the loss.
    function _checkMarketLoss(uint256 expected, uint256 actual) private view {
        uint256 index = market.totalsBasic().baseSupplyIndex;
        if (index < 1e15) revert InvalidConfiguration();
        uint256 tolerance = Math.ceilDiv(index, 1e15);
        if (actual < expected && expected - actual > tolerance) revert UnexpectedMarketLoss();
    }

    function _deadline(uint256 deadline) private view {
        if (block.timestamp > deadline) revert DeadlineExpired();
    }

    function _send(address receiver, uint256 assets) private {
        (bool success,) = payable(receiver).call{value: assets}("");
        if (!success) revert NativeTransferFailed();
    }

    receive() external payable {
        if (msg.sender != address(market) || expectedNative == 0 || msg.value != expectedNative) {
            revert UnexpectedNative();
        }
        expectedNative = 0;
    }
}
