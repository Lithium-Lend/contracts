# Independent contract analysis

Install `requirements.txt` in an isolated CPython 3.14 environment using `python -m pip install --require-hashes --only-binary=:all: -r security/requirements.txt`. Slither 0.11.6 and all dependencies are version and wheel-hash pinned. Foundry is pinned separately in CI.

Run `node script/run-slither.mjs token` and `node script/run-slither.mjs comet` from the repository root. `SLITHER_BIN` can select an isolated executable. Canonical standard JSON source paths avoid duplicate AST identities in platform-specific Foundry build output. These are analysis inputs, not deployment compiler inputs. Existing creation-bytecode and storage-layout gates remain authoritative for deployment reproduction.

All 102 detectors run against production sources. Dependency-only findings are filtered; dependency commit pins and deployment checks remain separate controls. Compiler/parser failure, incomplete coverage, and new medium/high findings fail the job. Lower-severity findings remain in the retained JSON and logs. Exceptions match individual findings and the complete source/settings input hash. Any production or imported source change requires re-review before those exceptions apply. Do not regenerate a baseline just to make CI pass.

The initial canonical run reported 135 lending-contract findings and two token timestamp findings. The 13 medium/high findings were reviewed as follows:

| Detector | Count | Review |
| --- | --- | --- |
| reentrancy-balance | 5 | Exact transfer-delta checks intentionally read balances before and after transfers. Current tokens are immutable standard ERC20 implementations without callbacks. Principal-changing entry points and native transfers use the shared assembly storage guard. Native-base callbacks into accounting are also guarded. The original ERC20-base `accrueAccount` is permissionless and unguarded, so this is not a claim that every function has a guard. Re-review if token semantics or any call path changes. |
| incorrect-equality | 6 | Exact `msg.value` validation, zero-supply division guards, and removal of empty collateral bitmap entries are intended accounting boundaries. They do not require equality with raw native contract balance. |
| unused-return | 2 | Markets consume prices from pinned adapters that validate positive answers, timestamps, and round completeness before returning. This exception depends on those adapters and does not resolve external oracle trust. |

Lower-severity review: loop calls read the immutable single-asset list and pinned feeds; callers can split liquidation batches. Assembly implements guarded storage, ERC20 return handling, and extension delegation. Native low-level calls check success. Timestamp dependence is expected for interest accrual, oracle freshness, and testnet faucet cooldowns, rather than randomness. Reentrancy event/order warnings share the transfer assumptions above. Naming notices do not affect execution. These observations are not blanket detector suppressions.

Regression evidence includes native callback rejection, token callback rejection in the native-base market, taxed-token rejection, oracle staleness rejection, collateral-cap enforcement, and the existing fuzz/invariant suites. Static analysis does not certify the protocol or replace an external audit.
