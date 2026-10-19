# Lithium Contracts

Public smart contracts for Lithium's USDC lending market on LitVM.

## LiteForge deployment

| Resource | Value |
| --- | --- |
| Network | LitVM LiteForge |
| Chain ID | `4441` |
| Market | [`0x9AAF...c9619`](https://liteforge.explorer.caldera.xyz/address/0x9AAF693E76547ab9423D680890F5c8432C4c9619) |
| Base token | [`0xc436...Bbed`](https://liteforge.explorer.caldera.xyz/address/0xc4361F046d767615ea70b8C65f7740CEB775Bbed) |
| Collateral | Native zkLTC |

The deployment manifest records the contract addresses, creation transactions,
source hashes, compiler targets, and pinned upstream revision.

## Repository layout

```text
src/testnet/   Lithium USDC testnet asset
script/        token deployment script
test/          token tests
comet/src/     Lithium Comet adaptations
comet/script/  market deployment and source publication
comet/test/    unit and invariant tests
comet/config/  active market configuration
comet/deployments/ canonical deployment manifest
lib/           pinned public dependencies
```

## Development

Install [Foundry](https://getfoundry.sh/) v1.8.0, initialize the submodules, and
run the test suites:

```sh
git submodule update --init --recursive
forge fmt --check
forge build src/testnet/LithiumUSDC.sol
forge test -vvv
cd comet
forge fmt --check
forge build --sizes --skip test --skip script
forge test -vvv
node script/verify-liteforge.mjs --check
```

## Source publication

The explorer publication script checks the exact source hashes and recorded
creation transactions before submitting source metadata:

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
