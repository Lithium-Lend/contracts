import assert from 'node:assert/strict';
import { mkdirSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { currentVerificationEntries } from './current-verification-input.mjs';
import { inspectVerification } from '../../script/lib/explorer-assurance.mjs';

const [mode = '--check', target] = process.argv.slice(2);
assert(['--check', '--submit'].includes(mode), 'Use --check or --submit <address>');
const entries = currentVerificationEntries();
console.log(`Checked ${entries.length} current verification inputs against the deployment build records.`);
if (mode === '--submit') {
  assert.match(target ?? '', /^0x[0-9a-fA-F]{40}$/, 'Submit one explicit current address');
  const entry = entries.find(e => e.address.toLowerCase() === target.toLowerCase());
  assert(entry, 'Address is not in the current supported deployment set');
  const output = resolve(`../attestation/verification-${target.toLowerCase()}.json`);
  mkdirSync(resolve('../attestation'), { recursive: true });
  const record = { address: entry.address, contract: entry.contract, inputSha256: entry.compilation.inputSha256, checkedAt: new Date().toISOString(), status: 'unconfirmed' };
  try {
    const before = await inspectVerification(entry);
    record.before = before;
    if (before.status === 'full') record.status = 'already-full';
    else {
      const body = new URLSearchParams({ module: 'contract', action: 'verifysourcecode',
        contractaddress: entry.address, sourceCode: entry.compilation.sourceCode,
        codeformat: 'solidity-standard-json-input', contractname: entry.contract,
        compilerversion: entry.compilation.compilerVersion, constructorArguments: entry.constructorArgs.slice(2),
      });
      const response = await fetch('https://liteforge.explorer.caldera.xyz/api/', { method: 'POST', body, signal: AbortSignal.timeout(30000) });
      assert(response.ok, `Explorer HTTP ${response.status}`);
      const result = await response.json();
      record.response = result;
      if (result.status === '1' && /^[0-9a-f]+$/i.test(String(result.result))) {
        record.requestId = result.result;
        record.status = 'submitted';
      } else if (/already verified/i.test(String(result.result))) record.status = 'explorer-reports-existing-source';
      else throw new Error('Explorer did not accept the source submission');
      record.after = await inspectVerification(entry);
      if (record.after.status === 'full') record.status = 'full';
    }
  } catch (error) {
    record.status = 'unconfirmed'; record.error = error.message;
  }
  writeFileSync(output, JSON.stringify(record, null, 2) + '\n');
  console.log(`${entry.address}: ${record.status}`);
  if (!['already-full', 'full'].includes(record.status)) process.exitCode = 1;
}
