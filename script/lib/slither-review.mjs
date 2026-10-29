import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';

export const sha256 = value => createHash('sha256').update(value).digest('hex');
export function checkAnalysis(report, input, review) {
  assert.equal(report.success, true, 'Analyzer did not complete successfully');
  assert.equal(report.error, null, 'Analyzer reported an error');
  assert(Array.isArray(report.results?.detectors), 'Missing detector results');
  assert.equal(sha256(input), review.analysisInputSha256, 'Production sources or analysis settings changed. Re-review the recorded exceptions.');
  const failures = report.results.detectors.filter(d => ['High', 'Medium'].includes(d.impact) && !review.accepted.some(a => a.id === d.id && a.check === d.check && a.impact === d.impact && a.reason));
  assert.equal(failures.length, 0, `Unreviewed findings: ${failures.map(d => `${d.check} ${d.id}`).join(', ')}`);
  return { findings: report.results.detectors.length, reviewedMediumHigh: report.results.detectors.filter(d => ['High', 'Medium'].includes(d.impact)).length };
}
