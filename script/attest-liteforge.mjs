import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import assert from 'node:assert/strict';
import { captureSnapshot, compareSnapshot, rpcClient, json } from './lib/chain-attestation.mjs';

const argv = process.argv.slice(2);
const options = {};
for (let i = 0; i < argv.length; i++) {
  const name = argv[i];
  assert(['--block', '--output', '--fail-on-health'].includes(name), `Unknown option ${name}`);
  assert(!Object.hasOwn(options, name), `Duplicate option ${name}`);
  options[name] = name === '--fail-on-health' ? true : argv[++i];
  assert(options[name] !== undefined, `Missing value ${name}`);
}
const expected = JSON.parse(readFileSync(new URL('../comet/config/liteforge-attestation.json', import.meta.url)));
let tag = 'latest';
if (options['--block']) {
  assert.match(options['--block'], /^\d+$/, 'Block must be a decimal number');
  tag = `0x${BigInt(options['--block']).toString(16)}`;
}
const output = resolve(options['--output'] ?? 'attestation/latest.json');
mkdirSync(dirname(output), { recursive: true });
try {
  const snapshot = await captureSnapshot(rpcClient(process.env.LITEFORGE_RPC_URL ?? expected.rpcUrl), expected, tag);
  const verdict = compareSnapshot(snapshot, expected);
  if (snapshot.blockNumber === expected.referenceBlock.number && snapshot.blockHash.toLowerCase() !== expected.referenceBlock.hash.toLowerCase()) verdict.errors.push('Reference block hash differs from the reviewed baseline');
  if (tag === 'latest' && (Date.now() / 1000 - snapshot.timestamp > 300 || snapshot.timestamp > Date.now() / 1000 + 60)) verdict.errors.push('RPC head timestamp is not current');
  verdict.stateMatches = verdict.errors.length === 0;
  writeFileSync(output, json({ ...snapshot, verdict, acceptedTrust: expected.acceptedTestnetTrust }));
  console.log(`Block ${snapshot.blockNumber}: ${verdict.errors.length} integrity failures, ${verdict.criticalHealthAlerts} critical health alerts.`);
  for (const error of verdict.errors) console.error(error);
  for (const alert of verdict.alerts) console.log(`${alert.level}: ${alert.market} ${alert.code}`);
  if (!verdict.stateMatches || (options['--fail-on-health'] && verdict.criticalHealthAlerts > 0)) process.exitCode = 1;
} catch (error) {
  writeFileSync(output, json({ observedAt: new Date().toISOString(), status: 'unavailable', error: error.message }));
  console.error(`Attestation failed: ${error.message}`);
  process.exitCode = 1;
}
