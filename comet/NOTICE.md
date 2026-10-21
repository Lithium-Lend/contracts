# Source and license notices

This package derives from Compound III by Compound Labs, copyright (c) 2025.

Upstream repository: https://github.com/compound-finance/comet

Pinned commit: `f766f51583c23acc33b2a7824654ef2029a96804`.

The complete upstream repository is tracked as the Git submodule
`../lib/comet`. Its original license and third-party notices are retained.
The pinned LICENSE specifies a Change Date no later than 2025-12-31 and a
Change License of GNU GPL v2.0 or later. This derivative package is distributed
under GPL-2.0-or-later; see [COPYING](COPYING). Vendored components retain their
respective notices. Lithium branding does not grant rights to Compound marks.

## Changes from the pinned core

`src/LithiumComet.sol` derives from
`contracts/CometWithExtendedAssetList.sol`, not a new handwritten lending engine.

- Rename the derivative and redirect imports to the pinned dependency.
- Restrict the market to a six-decimal USDC base and one native collateral.
- Replace the external asset-list factory with an immutable single-native list.
  Factors and caps retain exact configured values rather than being packed.
- Add payable caller-funded native collateral deposits and native transfers out.
- Append tracked native cash after inherited storage. Exclude forced native
  transfers from user collateral and liquidation sale inventory.
- Require exact base-token balance deltas on transfers.
- Retain Comet's collateral supply cap without aggregate base supply or borrow
  caps. The custom base caps in the first deployment were removed for the fresh market.
- Accrue interest before native collateral withdrawals and transfers.
- Guard absorption and reserve withdrawals against native callback reentry.
- Reject invalid recipients and base-token or native administrative approvals.
- Require rewards to remain disabled and validate configuration.
- Reject value sent through the extension fallback.

The separate price adapter checks source round validity and age, and normalizes
source prices to Comet's eight-decimal convention.

## Separate additional markets

`src/LithiumUSDTComet.sol` inherits the frozen `LithiumComet` implementation
without overriding behavior. It identifies a separately configured USDT-base
deployment, with native zkLTC collateral.

`src/LithiumNativeBaseComet.sol` is a separate derivative of `LithiumComet`
and the pinned Compound core. It changes the base asset to native zkLTC with
18 decimals and uses `LithiumErc20AssetList` for one six-decimal USDC collateral.
It adds explicit payable base supply, repayment, reserve funding, and collateral
purchases, tracked native base cash and ERC-20 collateral cash, exact recipient
token deltas, and an accrual callback guard. Forced native transfers and direct
collateral donations do not enter its accounting. The nonpayable upstream
collateral-purchase entry point reverts. Interest, principal, permission,
health-check, and liquidation formulas retain the pinned Comet model.
Neither new contract changes the historical USDC implementation or deployment.

These modifications have not received an independent audit. Tests of Lithium's
changes do not constitute upstream certification or an audit.
