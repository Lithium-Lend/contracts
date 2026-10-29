import assert from 'node:assert/strict';
import { readFileSync, writeFileSync, rmSync } from 'node:fs';
import { resolve } from 'node:path';
import { spawnSync } from 'node:child_process';
import { checkAnalysis } from './lib/slither-review.mjs';

const [project] = process.argv.slice(2);
assert(['token', 'comet'].includes(project), 'Select token or comet');
const executable = process.env.SLITHER_BIN ?? 'slither';
const version = spawnSync(executable, ['--version'], { encoding: 'utf8', windowsHide: true, timeout: 30000 });
assert.equal(version.status, 0, 'Slither unavailable');
assert.equal(version.stdout.trim(), '0.11.6', 'Use the pinned analyzer version');
const prepared = spawnSync(process.execPath, ['script/prepare-analysis.mjs', project], { encoding: 'utf8', windowsHide: true });
assert.equal(prepared.status, 0, prepared.stderr);
const output = resolve(`attestation/slither-${project}.json`);
rmSync(output, { force: true });
const result = spawnSync(executable, [resolve(`attestation/analysis-${project}.json`),
  '--compile-force-framework', 'solc-json', '--solc-working-dir', '.',
  '--json', output, '--fail-none', '--filter-paths', '(^|[/\\\\])lib([/\\\\]|$)',
], { cwd: project === 'comet' ? resolve('comet') : process.cwd(), encoding: 'utf8', windowsHide: true, timeout: 15 * 60 * 1000, maxBuffer: 20 * 1024 * 1024 });
const log = `${result.stdout ?? ''}\n${result.stderr ?? ''}`;
writeFileSync(resolve(`attestation/slither-${project}.log`), log);
assert.equal(result.status, 0, 'Analyzer execution failed; inspect the saved log');
assert(!/Missing inheritance|Missing params|Failed to resolve|Traceback|Error in|Error during/i.test(log), 'Incomplete analysis; inspect the saved log');
const counts = /analyzed \((\d+) contracts with (\d+) detectors\)/.exec(log);
assert(counts && Number(counts[1]) >= (project === 'comet' ? 14 : 11) && Number(counts[2]) >= 100, 'Incomplete detector coverage');
const review = JSON.parse(readFileSync(`security/slither-${project}-review.json`));
const summary = checkAnalysis(JSON.parse(readFileSync(output)), readFileSync(`attestation/analysis-${project}.json`), review);
console.log(JSON.stringify({ project, analyzer: version.stdout.trim(), contracts: Number(counts[1]), detectors: Number(counts[2]), ...summary }));
