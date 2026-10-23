# Lithium lending markets

Compound III-derived markets with one borrowable asset and one collateral asset.
Each proxy maintains its own liquidity, balances, interest, and liquidation state.

| Implementation | Base asset | Collateral |
| --- | --- | --- |
| `LithiumComet` | Six-decimal Lithium USDC | Native zkLTC |
| `LithiumUSDTComet` | Six-decimal Lithium USDT | Native zkLTC |
| `LithiumNativeBaseComet` | Native zkLTC | Six-decimal Lithium USDC |

`LithiumUSDTComet` inherits the existing stablecoin market behavior. The native
base implementation adds payable supply, repayment, and collateral purchases.
It tracks native cash separately from forced transfers and checks exact ERC20
collateral balance changes. Each implementation uses the pinned Comet interest,
principal, borrowing-power, and liquidation model.

The original USDC source logic and proxy address remain unchanged. Its collateral
cap was increased through a new implementation, alongside the other two markets.
Tests cover market
isolation, native callbacks, token transfers, liquidity exhaustion, repayment,
liquidation, reserve deficits, and differential behavior against Comet.

## Build and test

From the repository root, initialize the pinned dependencies and build the USDC
test asset before running the cross-compiler integration suite:

```sh
git submodule update --init --recursive
forge build src/testnet/LithiumUSDC.sol
cd comet
forge fmt --check
forge build --sizes --skip test --skip script
forge test -vvv
node script/check-market-boundaries.mjs
node research/rate-simulation.mjs
node research/additional-market-simulation.mjs --check
```

The Comet workspace uses Solidity 0.8.15, London, IR compilation, and 200 optimizer
runs. Testnet tokens use Solidity 0.8.30 and Shanghai. Run live fork tests with
the explicit RPC settings documented in their test files.

## Deployments

- [USDC](deployments/liteforge-lith-usdc.json)
- [USDT](deployments/liteforge-usdt.json)
- [Native zkLTC](deployments/liteforge-zkltc.json)
- [USDT faucet token](../deployments/liteforge-lith-usdt-token.json)
- [Collateral cap upgrades and current implementations](deployments/liteforge-collateral-cap-upgrades.json)

The creation manifests above are historical. Apply the cap upgrade record to
identify the current implementations behind the same three proxies. Its
transactions replace only the implementation pointer, without an initializer.
Collateral, supplied balances, debts, and allowances are preserved.

| Market | Collateral cap across all wallets |
| --- | ---: |
| USDC | 1,000 zkLTC |
| USDT | 1,000 zkLTC |
| zkLTC | 1,000,000 USDC |

The [shared schedule](config/shared-collateral-caps.json) contains the same
candidate amounts for testnet and mainnet. These amounts provide testing capacity;
they are not a production risk assessment. Mainnet activation requires measured
liquidation liquidity, funded reserves and liquidators, and approved loss limits.
Any revised mainnet amounts must be tested through this same schedule first.

The current additional markets use 60% borrowing and 70% liquidation thresholds.
Their risk settings are for valueless LiteForge testing. Target reserves are a
collateral-sale threshold, not proof of a funded reserve balance.

The [compiler manifest](deployments/liteforge-additional-build.json) identifies
all 72 source units and their exact byte content. To reproduce the additional
markets' creation bytecode and metadata with the specified compiler:

```sh
node script/prepare-additional-build.mjs /path/to/solc-0.8.15 /tmp/lithium-build
node script/verify-additional.mjs usdt --check
node script/verify-additional.mjs zkltc --check
node script/verify-additional.mjs token --check
```

The local checks do not submit sources or poll the explorer. Full explorer
verification of the additional markets is incomplete. Historical deployment
records remain available in [history/](deployments/history/).

The cap upgrades reuse the same complete source input and preserve all other
constructor settings. Their [build manifest](deployments/liteforge-cap-upgrade-build.json)
records the compiler input and bytecode hashes. Reproduce and check it with:

```sh
node script/prepare-cap-upgrade-build.mjs /path/to/solc-0.8.15 /tmp/lithium-cap-build
node script/check-cap-upgrades.mjs
```

## Integration

Use the selected market's proxy and base-asset decimals. An approval or position
in one market does not grant allowance or collateral in another. Native base
transactions must use the payable methods exposed by `LithiumNativeBaseComet`;
the inherited nonpayable collateral-purchase method is disabled.

Price adapters require valid, fresh source rounds and normalize prices to eight
decimals. Native liquidity reads must use `accountedNative()`. Forced donations
are excluded from lending liquidity.

See [NOTICE.md](NOTICE.md) for the changes to upstream Comet and
[SECURITY.md](../SECURITY.md) for security reporting.
