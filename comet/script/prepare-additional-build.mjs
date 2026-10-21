import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";
import { additionalCompleteInput } from "./additional-verification-input.mjs";

const [compiler, directory] = process.argv.slice(2);
assert(compiler && directory, "Usage: node prepare-additional-build.mjs <solc-0.8.15> <output-directory>");
const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const manifest = JSON.parse(readFileSync(resolve(root, "deployments/liteforge-additional-build.json")));
const input = additionalCompleteInput();
const version = spawnSync(compiler, ["--version"], { encoding: "utf8", windowsHide: true });
if (version.error) throw version.error;
assert.equal(version.status, 0, "Compiler version check failed");
assert.match(version.stdout, /Version: 0\.8\.15\+commit\.e14f2714(?:\.|\s|$)/, "Wrong compiler build");
const result = spawnSync(compiler, ["--standard-json"], {
  input: input.sourceCode, encoding: "utf8", windowsHide: true, maxBuffer: 100 * 1024 * 1024,
});
if (result.error) throw result.error;
assert.equal(result.status, 0, "Compilation failed");
const output = JSON.parse(result.stdout);
const errors = output.errors?.filter(error => error.severity === "error") ?? [];
assert.equal(errors.length, 0, JSON.stringify(errors));
const sha256 = value => createHash("sha256").update(value).digest("hex");
const checks = [];
for (const [contract, expected] of Object.entries(manifest.completeCreationSha256)) {
  const split = contract.lastIndexOf(":");
  const artifact = output.contracts[contract.slice(0, split)][contract.slice(split + 1)];
  const actual = sha256(Buffer.from(artifact.evm.bytecode.object, "hex"));
  assert.equal(actual, expected, `Bytecode or metadata changed: ${contract}`);
  checks.push({ contract, creationSha256: actual, metadataSha256: sha256(artifact.metadata) });
}
const outputDirectory = resolve(directory);
mkdirSync(outputDirectory, { recursive: true });
writeFileSync(resolve(outputDirectory, "input.json"), input.sourceCode);
writeFileSync(resolve(outputDirectory, "output.json"), result.stdout);
writeFileSync(resolve(outputDirectory, "build.json"), `${JSON.stringify({
  compilerVersion: input.compilerVersion,
  inputSha256: input.inputSha256,
  outputSha256: sha256(result.stdout),
  sourceCount: manifest.sources.length,
  filesystemImports: false,
  checks,
}, null, 2)}\n`);
console.log(`Prepared ${checks.length} contract types from one complete input. Bytecode and metadata hashes match.`);
console.log(`Build files: ${outputDirectory}`);
