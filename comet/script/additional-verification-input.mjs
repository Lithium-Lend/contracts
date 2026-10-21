import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const sha256 = value => createHash("sha256").update(value).digest("hex");

// Source-unit aliases preserve the deployment's parsing order when all imports
// are supplied in standard JSON. Solidity source text is preserved exactly.
function checkedSources() {
  const manifest = JSON.parse(readFileSync(resolve(root, "deployments/liteforge-additional-build.json")));
  const sources = {};
  const originalSources = {};
  for (const source of manifest.sources) {
    let content = readFileSync(resolve(root, source.path), "utf8").replace(/\r\n/g, "\n");
    if (source.lineEndings === "crlf") content = content.replace(/\n/g, "\r\n");
    else assert.equal(source.lineEndings, "lf");
    assert.equal(sha256(content), source.sha256, `Compilation source changed: ${source.path}`);
    assert(!Object.hasOwn(sources, source.unit), `Duplicate source unit: ${source.unit}`);
    sources[source.unit] = { content };
    assert(!Object.hasOwn(originalSources, source.originalUnit), `Duplicate original source: ${source.originalUnit}`);
    originalSources[source.originalUnit] = { content };
  }
  return { manifest, sources, originalSources };
}

export function additionalVerificationInput() {
  const { manifest, sources } = checkedSources();
  const input = { language: manifest.language, sources, settings: manifest.settings };
  const sourceCode = JSON.stringify(input);
  assert.equal(sha256(sourceCode), manifest.inputSha256, "Verification input changed");
  return { sourceCode, compilerVersion: manifest.compilerVersion, inputSha256: manifest.inputSha256 };
}

// Fresh deployments must use these same complete inputs for creation and verification.
// Existing deployments can have different executable bytes because of import order.
export function additionalCompleteInput() {
  const { manifest, originalSources } = checkedSources();
  const sourceCode = JSON.stringify({ language: manifest.language, sources: originalSources, settings: manifest.completeSettings });
  assert.equal(sha256(sourceCode), manifest.completeInputSha256, "Complete compiler input changed");
  return { sourceCode, compilerVersion: manifest.compilerVersion, inputSha256: manifest.completeInputSha256 };
}
