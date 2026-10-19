# Source and license notices

The Lithium Comet package derives from Compound III by Compound Labs,
copyright (c) 2025.

- Upstream: <https://github.com/compound-finance/comet>
- Pinned commit: `f766f51583c23acc33b2a7824654ef2029a96804`
- Dependency path: `lib/comet`

The upstream license and third-party notices remain available in the pinned
submodule. The Lithium derivative is distributed under GPL-2.0-or-later. See
[COPYING](COPYING).

## Lithium changes

- Support a six-decimal USDC base asset and native zkLTC collateral.
- Provide a single-native-asset list with explicit factors and supply caps.
- Add caller-funded native collateral supply and native transfers out.
- Track native cash separately from forced native transfers.
- Validate exact base-token balance deltas.
- Accrue interest before collateral withdrawals and transfers.
- Guard liquidation and reserve paths against native callback reentry.
- Validate recipients, administrative approvals, rewards, and configuration.
- Validate DIA price rounds, enforce freshness, and normalize feed precision.
