import assert from 'node:assert/strict';
import { readFileSync, readdirSync, mkdirSync, writeFileSync } from 'node:fs';
import { posix, resolve } from 'node:path';

const [project] = process.argv.slice(2);
assert(['token', 'comet'].includes(project), 'Select token or comet');
const root = resolve(project === 'comet' ? 'comet' : '.');
const sources = {};
const remappings = project === 'comet'
  ? ['comet/=../lib/comet/contracts/']
  : ['@openzeppelin/contracts/=lib/openzeppelin-contracts/contracts/'];
function visit(unit) {
  if (Object.hasOwn(sources, unit)) return;
  const content = readFileSync(resolve(root, unit), 'utf8').replace(/\r\n/g, '\n');
  sources[unit] = { content };
  for (const match of content.matchAll(/\bimport\s+(?:[^;]*?\bfrom\s+)?["']([^"']+)["']\s*;/g)) {
    let path = match[1];
    if (path.startsWith('.')) path = posix.normalize(posix.join(posix.dirname(unit), path));
    else {
      const mapping = remappings.find(r => path.startsWith(r.split('=')[0]));
      assert(mapping, `Unmapped import ${path}`);
      const [prefix, replacement] = mapping.split('=');
      path = replacement + path.slice(prefix.length);
    }
    visit(path);
  }
}
function visitDirectory(directory) {
  for (const entry of readdirSync(resolve(root, directory), { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
    if (entry.isDirectory()) visitDirectory(`${directory}/${entry.name}`);
    else if (entry.name.endsWith('.sol')) visit(`${directory}/${entry.name}`);
  }
}
visitDirectory('src');
// Canonical relative source units avoid duplicate AST identities from platform paths.
// This input is for static analysis. Deployment bytecode remains checked separately.
const input = { language: 'Solidity', sources, settings: {
  remappings, optimizer: { enabled: true, runs: 200 }, viaIR: true,
  evmVersion: project === 'comet' ? 'london' : 'shanghai',
} };
mkdirSync('attestation', { recursive: true });
writeFileSync(`attestation/analysis-${project}.json`, JSON.stringify(input));
console.log(`Prepared ${Object.keys(sources).length} canonical ${project} source units.`);
