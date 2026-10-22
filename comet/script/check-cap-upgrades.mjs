import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { additionalCompleteInput } from './additional-verification-input.mjs';

const read = path => readFileSync(new URL(path, import.meta.url), 'utf8').replaceAll('\r\n', '\n');
const json = path => JSON.parse(read(path));
const sha = value => createHash('sha256').update(value).digest('hex');
const record = json('../deployments/liteforge-collateral-cap-upgrades.json');
const build = json('../deployments/liteforge-cap-upgrade-build.json');
const caps = json('../config/shared-collateral-caps.json');
const baseline = additionalCompleteInput();
const input = JSON.parse(baseline.sourceCode);
assert.equal(record.chainId, 4441);
assert.equal(record.status, 'confirmed');
assert.equal(record.upgradeMethod, 'ProxyAdmin.upgrade(address,address)');
assert.equal(record.initializerCalled, false);
assert.equal(record.positionHandling, 'preserved');
assert.equal(record.capsSha256, sha(read('../config/shared-collateral-caps.json')));
assert.equal(build.originalInputSha256, baseline.inputSha256);
assert.equal(build.compilerVersion, baseline.compilerVersion);
assert.deepEqual(Object.keys(input.sources).sort(), Object.keys(build.sourceSha256).sort());
for (const [path, source] of Object.entries(input.sources)) assert.equal(sha(source.content), build.sourceSha256[path], `Source changed: ${path}`);
input.settings = build.settings;
assert.equal(sha(JSON.stringify(input)), build.inputSha256);
assert.equal(caps.mainnetDeploymentAuthorized, false);
assert.deepEqual(record.markets.map(market => market.id).sort(), Object.keys(caps.markets).sort());
for (const market of record.markets) {
  const original = json(`../deployments/liteforge-${market.id === 'usdc' ? 'lith-usdc' : market.id}.json`);
  assert.equal(market.proxy.toLowerCase(), original.comet.toLowerCase());
  assert(original.transactions.some(tx => tx.address.toLowerCase() === market.previousImplementation.toLowerCase()));
  assert.equal(market.newCap, caps.markets[market.id].supplyCap);
  assert(BigInt(market.newCap) > BigInt(market.oldCap));
  assert.equal(market.collateral.supplyCap, market.newCap);
  assert.equal(BigInt(`0x${market.constructorArgs.slice(-64)}`), BigInt(market.newCap));
  assert.equal(market.collateral.borrowCollateralFactor, '600000000000000000');
  assert.equal(market.collateral.liquidateCollateralFactor, '700000000000000000');
  assert.deepEqual(market.transactions.map(tx => tx.kind), ['deploy', 'upgrade']);
  for (const tx of market.transactions) {
    assert.match(tx.transactionHash, /^0x[0-9a-f]{64}$/);
    assert.match(tx.inputSha256, /^[0-9a-f]{64}$/);
    assert(tx.blockNumber > 0 && BigInt(tx.gasUsed) > 0n);
  }
}
console.log('Confirmed cap records, unchanged sources, historical proxies, and shared limits agree.');
