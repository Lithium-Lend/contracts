import assert from 'node:assert/strict';
import { readFileSync, mkdirSync, writeFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { inspectVerification } from './lib/explorer-assurance.mjs';

const args = process.argv.slice(2);
assert(args.length === 0 || (args.length === 2 && args[0] === '--output'), 'Use --output <file>');
const output = resolve(args[1] ?? 'attestation/explorer.json');
const baseline = JSON.parse(readFileSync(new URL('../comet/config/liteforge-attestation.json', import.meta.url)));
const contracts = [];
// Bound concurrency so an explorer incident does not generate a request storm.
for (let i = 0; i < baseline.components.length; i += 4) {
  contracts.push(...await Promise.all(baseline.components.slice(i, i + 4).map(c => inspectVerification(c))));
}
const counts = Object.fromEntries(['full', 'partial', 'published-unclassified', 'unverified', 'unknown'].map(status => [status, contracts.filter(c => c.status === status).length]));
mkdirSync(dirname(output), { recursive: true });
writeFileSync(output, JSON.stringify({ checkedAt: new Date().toISOString(), chainId: baseline.chainId, counts, contracts }, null, 2) + '\n');
console.log(JSON.stringify(counts));
if (counts.full !== contracts.length) {
  console.warn('Explorer assurance is incomplete. Source publication and local bytecode reproduction do not imply full explorer verification.');
  process.exitCode = 1;
}
