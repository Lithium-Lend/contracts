# Lithium Contracts

Smart contracts for Lithium's independent USDC, USDT, and native zkLTC lending
markets on LitVM. Each market has one borrowable asset and one collateral asset.

## LiteForge deployment

| Resource | Value |
| --- | --- |
| Network | LitVM LiteForge |
| Chain ID | `4441` |
| Application | [Lithium lending markets](https://www.lithiumlend.com/app) |
| User guide | [Markets, collateral caps, and wallet actions](https://www.lithiumlend.com/docs) |

| Market | Borrowable asset | Collateral | Contract |
| --- | --- | --- | --- |
| USDC | Lithium USDC | Native zkLTC | [`0x9AAF...c9619`](https://liteforge.explorer.caldera.xyz/address/0x9AAF693E76547ab9423D680890F5c8432C4c9619) |
| USDT | Lithium USDT | Native zkLTC | [`0x5AbB...3895`](https://liteforge.explorer.caldera.xyz/address/0x5AbB1216c61b36518a37Cd6dCC4733bf9aFe3895) |
| zkLTC | Native zkLTC | Lithium USDC | [`0x2CF2...2d3F`](https://liteforge.explorer.caldera.xyz/address/0x2CF2179ff3732bd681eA59b339abF86a57922d3F) |

All three markets use a 60% borrowing limit and a 70% liquidation threshold.
The additional markets' creation records start with zero supplied liquidity
and zero funded reserves. Those are historical snapshots, not current balances.
Borrowing requires available liquidity in the selected market's lending asset.

### Testnet faucets

| Token | Contract | Uses |
| --- | --- | --- |
| Lithium USDC (lithUSDC) | [0xc4361F046d767615ea70b8C65f7740CEB775Bbed](https://liteforge.explorer.caldera.xyz/address/0xc4361F046d767615ea70b8C65f7740CEB775Bbed) | Supply or repay USDC; collateral for zkLTC borrowing |
| Lithium USDT (lithUSDT) | [0xb341d9bce2C1Cee5ed2cD8B26d0F9EB420272A39](https://liteforge.explorer.caldera.xyz/address/0xb341d9bce2C1Cee5ed2cD8B26d0F9EB420272A39) | Supply or repay USDT |

Both are six-decimal, unbacked test tokens, not Circle or Tether assets. Each
wallet can claim 10,000 of each token every 24 hours, with separate cooldowns,
through the [Lithium faucet](https://www.lithiumlend.com/app/faucet). Claims
require zkLTC for gas and no token approval. Native zkLTC is available through
the [LitVM testnet portal](https://testnet.litvm.com).

### Collateral limits

The collateral caps are 1,000 zkLTC in each stablecoin market and 1,000,000 USDC
in the zkLTC market. Each limit applies to all collateral in that market, across
all wallets. The [cap upgrade record](comet/deployments/liteforge-collateral-cap-upgrades.json)
records the current implementations. Market addresses and positions are retained.
Users do not need to withdraw and redeposit. A higher cap adds collateral room,
not lending liquidity, reserve funding, or liquidator funding. The USDC and USDT
markets have separate caps even though both accept zkLTC. No aggregate base
supply or borrow caps are imposed.
These are testnet capacity limits and candidate mainnet limits; production use
requires the liquidity and funding review in the
[shared schedule](comet/config/shared-collateral-caps.json).

The deployment manifest records the contract addresses, creation transactions,
source hashes, compiler targets, and pinned upstream revision.
See the [market guide](comet/README.md) and the [USDT](comet/deployments/liteforge-usdt.json)
and [zkLTC](comet/deployments/liteforge-zkltc.json) manifests for the additional markets.

## Repository layout

```text
src/testnet/   Lithium USDC and USDT testnet assets
script/        token deployment scripts
test/          token tests
comet/src/     Lithium Comet adaptations
comet/script/  market deployment and source publication
comet/test/    unit and invariant tests
comet/config/  active market configuration
comet/deployments/ deployment manifests and compiler inputs
comet/research/ deterministic interest and liquidation models
abi/           compiled contract and extension interfaces
lib/           pinned public dependencies
```

## Development

Install [Foundry](https://getfoundry.sh/) v1.8.0, initialize the submodules, and
run the test suites:

```sh
git submodule update --init --recursive
forge fmt --check
forge build src/testnet/LithiumUSDC.sol src/testnet/LithiumUSDT.sol
forge test -vvv
cd comet
forge fmt --check
forge build --sizes --skip test --skip script
forge test -vvv
node script/verify-liteforge.mjs --check
node script/verify-additional.mjs usdt --check
node script/verify-additional.mjs zkltc --check
node script/verify-additional.mjs token --check
node script/check-market-boundaries.mjs
node research/additional-market-simulation.mjs --check
```

## Source publication

The USDT token is source-verified on LiteForge. Full explorer verification of
the market contracts is incomplete; the manifests record individual results.
Verification of the current cap upgrade implementations is deferred. The
supplied compiler manifests reproduce the complete deployment inputs, including
Solidity metadata.

Applications can pin a repository commit and consume the interfaces in `abi/`
alongside its deployment manifests. Comet proxies expose both their market
implementation and `CometExt` functions. `script/check-abis.mjs` compares the
exported interfaces with the compiled artifacts.

The explorer publication script checks the exact source hashes and recorded
creation transactions before submitting source metadata. The commands below
target the historical USDC deployment, not its later cap upgrade. Use the
[cap upgrade record](comet/deployments/liteforge-collateral-cap-upgrades.json)
and its compiler manifest to identify current implementations:

```sh
cd comet
node script/verify-liteforge.mjs --check
node script/verify-liteforge.mjs --submit
```

## Upstream and license

The market core derives from the pinned
[`compound-finance/comet`](https://github.com/compound-finance/comet) revision.
See [NOTICE.md](NOTICE.md) for the modification summary and [COPYING](COPYING)
for GPL-2.0-or-later terms. Individual source files retain their SPDX license
identifiers.
