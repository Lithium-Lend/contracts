# Contributing

Contributions should be focused, reviewable, and covered by tests.

1. Open an issue or discussion for substantial behavior changes.
2. Create a branch from `main`.
3. Add or update tests with the implementation.
4. Run the complete local validation suite.
5. Open a pull request with a short, plain description of what it adds or fixes.
   Keep check results, internal process notes, and assistant attribution out of
   the title and description. Continue performing the required checks.

Do not commit secrets, private keys, seed phrases, RPC credentials, generated
build output, or deployment signing material.

## Validation

```sh
forge fmt --check
forge build src/testnet/LithiumUSDC.sol src/testnet/LithiumUSDT.sol
forge test -vvv
cd comet
forge fmt --check
forge build --sizes --skip test --skip script
forge test -vvv
node script/verify-liteforge.mjs --check
```
