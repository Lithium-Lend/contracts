import test from 'node:test';
import assert from 'node:assert/strict';
import { checkAnalysis, sha256 } from './lib/slither-review.mjs';

const input = Buffer.from('reviewed sources');
const finding = { id: 'known', check: 'reentrancy-balance', impact: 'High' };
const review = { analysisInputSha256: sha256(input), accepted: [{ ...finding, reason: 'Reviewed guarded path.' }] };
const report = { success: true, error: null, results: { detectors: [finding] } };
test('only exact reviewed findings pass for unchanged sources', () => {
  assert.equal(checkAnalysis(report, input, review).reviewedMediumHigh, 1);
  assert.throws(() => checkAnalysis(report, Buffer.from('modified guard'), review));
  assert.throws(() => checkAnalysis({ ...report, results: { detectors: [{ ...finding, id: 'new' }] } }, input, review));
});
test('failed or malformed analysis never passes', () => {
  assert.throws(() => checkAnalysis({ ...report, success: false }, input, review));
  assert.throws(() => checkAnalysis({ ...report, error: 'parser failure' }, input, review));
  assert.throws(() => checkAnalysis({ ...report, results: {} }, input, review));
});
