import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const baseline = "81e665ab2f9db9d749c2fc1f8d96828ff9e81499";
const protectedPaths = [
  "comet/src/LithiumComet.sol",
  "comet/src/LithiumNativeAssetList.sol",
  "comet/src/LithiumCometPriceFeed.sol",
  "comet/script/DeployLithiumComet.s.sol",
  "comet/config/liteforge.lith-usdc.json",
  "comet/deployments/liteforge-lith-usdc.json",
  "src/testnet/LithiumUSDC.sol",
];
const root = new URL("../../", import.meta.url);
const rootPath = fileURLToPath(root);
const manifest = JSON.parse(readFileSync(new URL("../config/frozen-usdc-boundary.json", import.meta.url), "utf8"));

function normalize(source) {
  return source.replaceAll("\r\n", "\n");
}

function sha256(source) {
  return createHash("sha256").update(source).digest("hex");
}

function git(args) {
  return execFileSync("git", args, {
    cwd: rootPath,
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  });
}

assert.equal(manifest.baseline, baseline, "Existing USDC boundary manifest must name the pinned baseline commit");
assert.equal(manifest.normalization, "LF", "Existing USDC boundary manifest must use LF normalization");
assert.deepEqual(
  Object.keys(manifest.sourceSha256).sort(),
  [...protectedPaths].sort(),
  "Existing USDC boundary manifest must contain exactly the protected path set",
);

git(["cat-file", "-e", `${baseline}^{commit}`]);
git(["merge-base", "--is-ancestor", baseline, "HEAD"]);

for (const path of protectedPaths) {
  const baselineSource = normalize(git(["show", `${baseline}:${path}`]));
  const baselineHash = sha256(baselineSource);
  assert.equal(
    manifest.sourceSha256[path],
    baselineHash,
    `Existing USDC boundary manifest does not match the pinned baseline: ${path}`,
  );

  const currentSource = normalize(readFileSync(new URL(path, root), "utf8"));
  if (path === "comet/config/liteforge.lith-usdc.json") {
    const record = JSON.parse(git(["show", `${baseline}:comet/deployments/liteforge-lith-usdc.json`]));
    assert.deepEqual(JSON.parse(currentSource), { ...JSON.parse(baselineSource), deployer: record.deployer },
      "Only the existing deployer metadata may be added to the USDC configuration");
    continue;
  }
  assert.equal(sha256(currentSource), baselineHash, `Existing USDC boundary changed: ${path}`);
}

console.log(`Existing USDC boundary unchanged (${protectedPaths.length} files, baseline ${baseline}, ${rootPath}).`);
