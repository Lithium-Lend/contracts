import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const mode = process.argv[2] ?? "--check";
assert(["--check", "--submit"].includes(mode), "Use --check or --submit");

const cometRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const contractsRoot = resolve(cometRoot, "..");
const deployment = JSON.parse(readFileSync(
  join(cometRoot, "deployments", "liteforge-lith-usdc.json"),
  "utf8",
));

function sha256(path) {
  return createHash("sha256").update(readFileSync(path)).digest("hex");
}

for (const [path, expected] of Object.entries(deployment.sourceSha256)) {
  assert.equal(sha256(join(cometRoot, path)), expected, `Deployment source changed: ${path}`);
}
assert.equal(
  sha256(join(contractsRoot, "src", "testnet", "LithiumUSDC.sol")),
  deployment.tokenSourceSha256,
  "Deployment source changed: src/testnet/LithiumUSDC.sol",
);

const transactionByAddress = new Map(
  deployment.transactions.map((transaction) => [transaction.address.toLowerCase(), transaction]),
);
assert.equal(transactionByAddress.size, deployment.transactions.length, "Duplicate creation addresses");
const rpcUrl = "https://liteforge.rpc.caldera.xyz/http";
const verifierUrl = "https://liteforge.explorer.caldera.xyz/api/";
const cometOptions = [
  "--profile", "liteforge",
  "--compilation-profile", "london",
  "--compiler-version", "0.8.15",
  "--evm-version", "london",
  "--via-ir",
  "--num-of-optimizations", "200",
];
const tokenOptions = [
  "--compiler-version", "0.8.30",
  "--evm-version", "shanghai",
  "--via-ir",
  "--num-of-optimizations", "200",
];
const contracts = [
  {
    name: "LithiumUSDC",
    address: deployment.baseToken,
    contract: "src/testnet/LithiumUSDC.sol:LithiumUSDC",
    cwd: contractsRoot,
    options: tokenOptions,
  },
  {
    name: "LithiumCometPriceFeed",
    address: deployment.transactions[1].address,
    contract: "src/LithiumCometPriceFeed.sol:LithiumCometPriceFeed",
    cwd: cometRoot,
    options: cometOptions,
  },
  {
    name: "LithiumCometPriceFeed",
    address: deployment.transactions[2].address,
    contract: "src/LithiumCometPriceFeed.sol:LithiumCometPriceFeed",
    cwd: cometRoot,
    options: cometOptions,
  },
  {
    name: "CometExt",
    address: deployment.transactions[3].address,
    contract: "../lib/comet/contracts/CometExt.sol:CometExt",
    cwd: cometRoot,
    options: cometOptions,
    constructorArgs: "0x4c69746869756d205553444300000000000000000000000000000000000000006c69555344430000000000000000000000000000000000000000000000000000",
  },
  {
    name: "ProxyAdmin",
    address: deployment.transactions[4].address,
    contract: "../lib/comet/contracts/vendor/proxy/transparent/ProxyAdmin.sol:ProxyAdmin",
    cwd: cometRoot,
    options: cometOptions,
  },
  {
    name: "LithiumComet",
    address: deployment.transactions[5].address,
    contract: "src/LithiumComet.sol:LithiumComet",
    cwd: cometRoot,
    options: cometOptions,
  },
  {
    name: "LithiumNativeAssetList",
    address: deployment.assetList.address,
    contract: "src/LithiumNativeAssetList.sol:LithiumNativeAssetList",
    cwd: cometRoot,
    options: cometOptions,
    constructorArgs: "0x0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000970fb75b1f2767ca2f95a6f1a42fb9acd730965300000000000000000000000000000000000000000000000000000000000000120000000000000000000000000000000000000000000000000853a0d2313c000000000000000000000000000000000000000000000000000009b6e64a8ec600000000000000000000000000000000000000000000000000000c7d713b49da00000000000000000000000000000000000000000000000000008ac7230489e80000",
  },
  {
    name: "TransparentUpgradeableProxy",
    address: deployment.comet,
    contract: "../lib/comet/contracts/vendor/proxy/transparent/TransparentUpgradeableProxy.sol:TransparentUpgradeableProxy",
    cwd: cometRoot,
    options: cometOptions,
  },
];

for (const entry of contracts) {
  const transaction = transactionByAddress.get(entry.address.toLowerCase());
  if (!transaction) {
    assert(entry.constructorArgs, `Missing creation transaction or explicit constructor arguments for ${entry.address}`);
    continue;
  }
  assert.equal(transaction.contractName, entry.name, `Wrong contract at ${entry.address}`);
  assert.match(transaction.transactionHash, /^0x[0-9a-fA-F]{64}$/, `Invalid creation hash for ${entry.address}`);
  assert.notEqual(BigInt(transaction.transactionHash), 0n, `Missing creation hash for ${entry.address}`);
  entry.transactionHash = transaction.transactionHash;
}

console.log(`Checked exact source hashes and verification inputs for ${contracts.length} LiteForge contracts.`);
if (mode === "--check") process.exit(0);

for (const entry of contracts) {
  const args = [
    "verify-contract",
    "--root", ".",
    "--watch",
    "--chain", String(deployment.chainId),
    "--rpc-url", rpcUrl,
    entry.address,
    entry.contract,
    "--verifier", "blockscout",
    "--verifier-url", verifierUrl,
    ...entry.options,
    "--retries", "5",
    "--delay", "5",
  ];
  if (entry.constructorArgs) args.push("--constructor-args", entry.constructorArgs);
  else args.push(
    "--guess-constructor-args",
    "--creation-transaction-hash", entry.transactionHash,
  );
  console.log(`Submitting ${entry.name} at ${entry.address}`);
  const result = spawnSync("forge", args, { cwd: entry.cwd, stdio: "inherit", windowsHide: true });
  if (result.error) throw result.error;
  assert.equal(result.status, 0, `Verification failed for ${entry.address}`);
}
