import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const results = JSON.parse(readFileSync(process.argv[2], 'utf8'));
const required = {
  LiteForgeCometForkTest: 8,
  LiteForgeFreshMarketForkTest: 8,
  LiteForgeCurrentDeploymentForkTest: 2,
};
for (const [name, minimum] of Object.entries(required)) {
  const suites = Object.entries(results).filter(([key]) => key.endsWith(`:${name}`));
  assert.equal(suites.length, 1, `Missing or duplicated suite ${name}`);
  const tests = Object.values(suites[0][1].test_results);
  assert(tests.length >= minimum, `Missing tests in ${name}`);
  assert(tests.every(t => t.status === 'Success'), `Failed or skipped test in ${name}`);
  console.log(`${name}: ${tests.length} passed, none skipped.`);
}
