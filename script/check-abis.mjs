import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const root = new URL("../", import.meta.url);
for (const [name, directory] of [
  ["LithiumComet", "comet/out"],
  ["LithiumUSDTComet", "comet/out"],
  ["LithiumNativeBaseComet", "comet/out"],
  ["CometExt", "comet/out"],
  ["LithiumUSDC", "out"],
  ["LithiumUSDT", "out"],
]) {
  const artifact = JSON.parse(readFileSync(new URL(`${directory}/${name}.sol/${name}.json`, root)));
  const published = JSON.parse(readFileSync(new URL(`abi/${name}.json`, root)));
  assert.deepEqual(published, artifact.abi, `${name}: exported ABI differs from compiled source`);
}
console.log(`Published ABIs match all six compiled contracts (${fileURLToPath(root)}).`);
