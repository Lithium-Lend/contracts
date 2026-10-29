import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { additionalCompleteInput } from './additional-verification-input.mjs';
import { cast, same, word } from '../../script/lib/chain-attestation.mjs';

export function currentVerificationEntries() {
  const baseline = JSON.parse(readFileSync(new URL('../config/liteforge-attestation.json', import.meta.url)));
  const additional = additionalCompleteInput();
  const capInput = JSON.parse(additional.sourceCode);
  const fields = ['abi', 'metadata', 'storageLayout', 'evm.bytecode.object', 'evm.deployedBytecode.object', 'evm.deployedBytecode.immutableReferences'];
  for (const name of ['LithiumComet', 'LithiumUSDTComet', 'LithiumNativeBaseComet']) capInput.settings.outputSelection[`src/${name}.sol`] = { [name]: fields };
  const sourceCode = JSON.stringify(capInput);
  const inputSha256 = createHash('sha256').update(sourceCode).digest('hex');
  const build = JSON.parse(readFileSync(new URL('../deployments/liteforge-cap-upgrade-build.json', import.meta.url)));
  assert.equal(inputSha256, build.inputSha256, 'Cap deployment compiler input changed');
  const capCompilation = { sourceCode, inputSha256, compilerVersion: additional.compilerVersion };
  const upgrades = JSON.parse(readFileSync(new URL('../deployments/liteforge-collateral-cap-upgrades.json', import.meta.url)));
  const entries = [];
  for (const market of upgrades.markets) {
    const expected = baseline.markets.find(m => m.id === market.id);
    assert(same(market.implementation, expected.implementation) && same(market.assetList, expected.assetList));
    entries.push({ address: market.implementation, contract: market.contract, constructorArgs: market.constructorArgs, compilation: capCompilation });
    const c = market.collateral;
    const decimals = c.asset === `0x${'0'.repeat(40)}` ? 18 : 6;
    const args = cast(['abi-encode', 'constructor((address,address,uint8,uint64,uint64,uint64,uint128))', `(${c.asset},${c.priceFeed},${decimals},${c.borrowCollateralFactor},${c.liquidateCollateralFactor},${c.liquidationFactor},${c.supplyCap})`]);
    assert.equal(args.length, 2 + 7 * 64);
    assert.equal(word(`0x${market.constructorArgs.slice(-8 * 64)}`), 1n, 'Expected one deployed asset');
    assert(market.constructorArgs.toLowerCase().endsWith(args.slice(2).toLowerCase()), 'Asset constructor differs from implementation configuration');
    const name = market.id === 'zkltc' ? 'LithiumErc20AssetList' : 'LithiumNativeAssetList';
    entries.push({ address: market.assetList, contract: `src/${name}.sol:${name}`, constructorArgs: args, compilation: capCompilation });
  }
  for (const id of ['usdt', 'zkltc']) {
    const deployment = JSON.parse(readFileSync(new URL(`../deployments/liteforge-${id}.json`, import.meta.url)));
    assert.equal(deployment.compilerInput.inputSha256, additional.inputSha256);
    for (const entry of deployment.transactions) {
      if (baseline.components.some(c => same(c.address, entry.address))) entries.push({ address: entry.address, contract: entry.contract, constructorArgs: entry.constructorArgs, compilation: additional });
    }
  }
  assert.equal(new Set(entries.map(e => e.address.toLowerCase())).size, entries.length);
  for (const entry of entries) {
    assert.match(entry.constructorArgs, /^0x(?:[a-fA-F0-9]{64})*$/);
    const [source] = entry.contract.split(':');
    assert(JSON.parse(entry.compilation.sourceCode).sources[source], `Missing source ${source}`);
  }
  // Preserve every source byte and compiler setting except output selection.
  // The committed proofs are independently reproduced by the compiler in CI.
  const proofs = JSON.parse(readFileSync(new URL('../config/current-verification-inputs.json', import.meta.url)));
  assert.equal(proofs.compilerVersion, additional.compilerVersion);
  for (const entry of entries) {
    const proof = proofs.entries.find(p => p.contract === entry.contract);
    assert(proof, `Missing exact verification proof for ${entry.contract}`);
    const input = JSON.parse(entry.compilation.sourceCode);
    input.sources = Object.fromEntries(Object.entries(input.sources).filter(([unit]) => proof.sourceUnits.includes(unit)));
    assert.equal(Object.keys(input.sources).length, proof.sourceUnits.length, 'Missing required source');
    const [unit, name] = entry.contract.split(':');
    input.settings.outputSelection = { [unit]: { [name]: ['abi', 'metadata', 'evm.bytecode.object', 'evm.deployedBytecode.object', 'evm.deployedBytecode.immutableReferences'] } };
    const reduced = JSON.stringify(input);
    const digest = createHash('sha256').update(reduced).digest('hex');
    assert.equal(digest, proof.inputSha256, `Reduced input changed: ${entry.contract}`);
    entry.compilation = { sourceCode: reduced, inputSha256: digest, deploymentInputSha256: entry.compilation.inputSha256, compilerVersion: additional.compilerVersion };
  }
  return entries;
}
