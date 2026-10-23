import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { spawnSync } from 'node:child_process';
import { additionalCompleteInput } from './additional-verification-input.mjs';

const [compiler, destination] = process.argv.slice(2);
assert(compiler && destination, 'Usage: node prepare-cap-upgrade-build.mjs <solc-0.8.15> <destination>');
const sha = value => createHash('sha256').update(value).digest('hex');
const baseline = additionalCompleteInput();
const input = JSON.parse(baseline.sourceCode);
const names = ['LithiumComet', 'LithiumUSDTComet', 'LithiumNativeBaseComet'];
const fields = ['abi', 'metadata', 'storageLayout', 'evm.bytecode.object', 'evm.deployedBytecode.object', 'evm.deployedBytecode.immutableReferences'];
for (const name of names) input.settings.outputSelection[`src/${name}.sol`] = { [name]: fields };
const sourceCode = JSON.stringify(input);
const version = spawnSync(compiler, ['--version'], { encoding: 'utf8', windowsHide: true });
if (version.error) throw version.error;
assert.equal(version.status, 0);
assert.match(version.stdout, /Version: 0\.8\.15\+commit\.e14f2714(?:\.|\s|$)/);
const compiled = spawnSync(compiler, ['--standard-json'], { input: sourceCode, encoding: 'utf8', windowsHide: true, maxBuffer: 100 * 1024 * 1024 });
if (compiled.error) throw compiled.error;
assert.equal(compiled.status, 0);
const output = JSON.parse(compiled.stdout);
assert.equal(output.errors?.filter(e => e.severity === 'error').length ?? 0, 0);
const previous = JSON.parse(readFileSync(new URL('../deployments/liteforge-additional-build.json', import.meta.url)));
const checks = [];
for (const name of names) {
  const artifact = output.contracts[`src/${name}.sol`][name];
  const creationSha256 = sha(Buffer.from(artifact.evm.bytecode.object, 'hex'));
  if (name !== 'LithiumComet') assert.equal(creationSha256, previous.completeCreationSha256[`src/${name}.sol:${name}`], 'Previously deployed creation code changed');
  const storage = artifact.storageLayout.storage;
  assert.deepEqual(storage.map(s => [s.label, s.slot, s.offset]), [
    ['baseSupplyIndex', '0', 0], ['baseBorrowIndex', '0', 8], ['trackingSupplyIndex', '0', 16], ['trackingBorrowIndex', '0', 24],
    ['totalSupplyBase', '1', 0], ['totalBorrowBase', '1', 13], ['lastAccrualTime', '1', 26], ['pauseFlags', '1', 31],
    ['totalsCollateral', '2', 0], ['isAllowed', '3', 0], ['userNonce', '4', 0], ['userBasic', '5', 0], ['userCollateral', '6', 0], ['liquidatorPoints', '7', 0],
    ['accountedNative', '8', 0], ...(name === 'LithiumNativeBaseComet' ? [['accountedCollateral', '9', 0]] : []),
  ]);
  checks.push({ contract: name, creationSha256, storageLayoutSha256: sha(JSON.stringify(artifact.storageLayout)), storageEntries: storage.length, runtimeBytes: artifact.evm.deployedBytecode.object.length / 2 });
  assert(artifact.evm.deployedBytecode.object.length / 2 <= 24576);
}
const recordedPath = new URL('../deployments/liteforge-cap-upgrade-build.json', import.meta.url);
if (existsSync(recordedPath)) {
  const recorded = JSON.parse(readFileSync(recordedPath, 'utf8'));
  assert.equal(sha(sourceCode), recorded.inputSha256, 'Complete compiler input differs from deployed build');
  assert.deepEqual(checks, recorded.checks, 'Creation bytecode or storage layout differs from deployed build');
}
mkdirSync(destination, { recursive: true });
writeFileSync(resolve(destination, 'input.json'), sourceCode);
writeFileSync(resolve(destination, 'output.json'), compiled.stdout);
writeFileSync(resolve(destination, 'build.json'), JSON.stringify({ compilerVersion: baseline.compilerVersion, originalInputSha256: baseline.inputSha256, inputSha256: sha(sourceCode), outputSha256: sha(compiled.stdout), sourceCount: Object.keys(input.sources).length, originalSourcesUnchanged: true, checks }, null, 2) + '\n');
console.log(JSON.stringify({ sourceCount: Object.keys(input.sources).length, checks }, null, 2));
