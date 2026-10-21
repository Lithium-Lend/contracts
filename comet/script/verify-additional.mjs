import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";
import { additionalCompleteInput } from "./additional-verification-input.mjs";

const [id, mode = "--check"] = process.argv.slice(2);
assert(["zkltc", "usdt", "token"].includes(id), "Select zkltc, usdt, or token");
assert(["--check", "--submit", "--status"].includes(mode), "Use --check, --submit, or --status");
const token = id === "token";
const cometRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const cwd = token ? resolve(cometRoot, "..") : cometRoot;
const recordPath = resolve(cwd, "deployments", `liteforge-${token ? "lith-usdt-token" : id}.json`);
const record = JSON.parse(readFileSync(recordPath));
const compilation = token ? null : additionalCompleteInput();
if (!token) {
  assert.equal(record.compilerInput?.format, "complete-standard-json", "Complete deployment compiler input is required");
  assert.equal(record.compilerInput.inputSha256, compilation.inputSha256, "Deployment and verification inputs differ");
}
assert.equal(record.chainId, 4441);
for (const [source, expected] of Object.entries(record.sourceSha256)) {
  const raw = readFileSync(resolve(cwd, source), "utf8");
  const lf = raw.replace(/\r\n/g, "\n");
  const hashes = [raw, lf, lf.replace(/\n/g, "\r\n")].map(content => createHash("sha256").update(content).digest("hex"));
  assert(hashes.includes(expected), `Deployment source changed: ${source}`);
}
const entries = [...record.transactions, ...(record.assetList ? [record.assetList] : [])];
for (const entry of entries) {
  assert.match(entry.address, /^0x[\da-fA-F]{40}$/);
  assert.match(entry.constructorArgs, /^0x[\da-fA-F]*$/);
  assert(entry.contract.includes(":"));
}
console.log(`Checked ${entries.length} additional ${id} contracts and deployment source hashes.`);
if (mode === "--submit" && !token) {
  const failed = [];
  for (const entry of entries) {
    if (entry.sourceVerification === "verified-on-blockscout") continue;
    try {
      if (entry.verificationRequestId && entry.sourceVerificationInputSha256 === compilation.inputSha256) {
        const query = new URLSearchParams({ module: "contract", action: "checkverifystatus", guid: entry.verificationRequestId });
        const response = await fetch(`https://liteforge.explorer.caldera.xyz/api/?${query}`, { signal: AbortSignal.timeout(20_000) });
        const request = await response.json();
        if (/Pending in queue|Pass - Verified/.test(String(request.result))) {
          console.log(`${entry.address}: ${request.result}`);
          continue;
        }
      }
      const body = new URLSearchParams({
        module: "contract", action: "verifysourcecode", contractaddress: entry.address,
        sourceCode: compilation.sourceCode, codeformat: "solidity-standard-json-input",
        contractname: entry.contract, compilerversion: compilation.compilerVersion,
        constructorArguments: entry.constructorArgs.slice(2),
      });
      let result;
      for (let attempt = 0; attempt < 3; attempt++) {
        const response = await fetch("https://liteforge.explorer.caldera.xyz/api/", {
          method: "POST", body, signal: AbortSignal.timeout(45_000),
        });
        result = await response.json();
        if (result.status === "1" || /already verified/i.test(String(result.result))) break;
        if (attempt < 2) await new Promise(resolve => setTimeout(resolve, 5_000));
      }
      if (/already verified/i.test(String(result.result))) {
        console.log(`Explorer reports already verified: ${entry.address}`);
        continue;
      }
      assert.equal(result.status, "1", JSON.stringify(result));
      assert.match(result.result, /^[a-fA-F0-9]+$/, "Unexpected verification request ID");
      entry.verificationRequestId = result.result;
      entry.sourceVerification = "submitted";
      entry.sourceSubmittedAt = new Date().toISOString();
      entry.sourceVerificationInputSha256 = compilation.inputSha256;
      delete entry.sourceVerificationError;
      console.log(`Submitted ${entry.name}: ${entry.address} (${entry.verificationRequestId})`);
    } catch (error) {
      failed.push(entry.address);
      entry.sourceVerification = "submission-failed";
      entry.sourceVerificationError = error.message.split("\n")[0];
      console.error(`Submission failed ${entry.address}: ${entry.sourceVerificationError}`);
    }
    record.sourceVerification = "verification-incomplete";
    writeFileSync(recordPath, `${JSON.stringify(record, null, 2)}\n`);
  }
  assert.equal(failed.length, 0, `Submission failed for ${failed.join(", ")}`);
  console.log("Source submitted. Use --status to confirm completed explorer verification.");
}
if (mode === "--submit" && token) {
  for (const entry of entries) {
    const options = ["--compiler-version", "0.8.30", "--evm-version", "shanghai"];
    // The explorer's ABI precheck can fail while newly deployed addresses are indexed.
    const args = ["verify-contract", "--root", ".", "--watch", "--skip-is-verified-check", "--chain", "4441", "--rpc-url",
      "https://liteforge.rpc.caldera.xyz/http", entry.address, entry.contract, "--verifier", "blockscout",
      "--verifier-url", "https://liteforge.explorer.caldera.xyz/api/", ...options, "--via-ir",
      "--num-of-optimizations", "200", "--constructor-args", entry.constructorArgs, "--retries", "30", "--delay", "5"];
    console.log(`Verifying ${entry.name} at ${entry.address}`);
    const result = spawnSync("forge", args, { cwd, stdio: "inherit", windowsHide: true });
    if (result.error) throw result.error;
    assert.equal(result.status, 0, `Verification failed for ${entry.address}`);
  }
}
if (mode === "--status" || (mode === "--submit" && token)) {
  const failures = [];
  for (const entry of entries) {
    try {
      let response;
      for (let attempt = 0; attempt < 3; attempt++) {
        response = await fetch(`https://liteforge.explorer.caldera.xyz/api/v2/smart-contracts/${entry.address}`, {
          signal: AbortSignal.timeout(20_000),
        });
        if (response.status < 500 || attempt === 2) break;
        await new Promise(resolve => setTimeout(resolve, 5_000));
      }
      assert(response.ok, `Explorer HTTP ${response.status}`);
      const published = await response.json();
      assert.equal(published.is_verified, true, "Source not verified");
      const source = entry.contract.split(":")[0];
      assert.equal(typeof published.source_code, "string", "Published source is unavailable");
      assert.equal(published.source_code.replace(/\r\n/g, "\n"), readFileSync(resolve(cwd, source), "utf8").replace(/\r\n/g, "\n"), "Published source differs");
      // The explorer may verify runtime code before indexing the creation transaction.
      // Exact creation inputs are independently recorded from the broadcast transaction.
      if (typeof published.constructor_args === "string") {
        assert.equal(published.constructor_args.replace(/^0x/, "").toLowerCase(), entry.constructorArgs.slice(2).toLowerCase(), "Constructor inputs differ");
      }
      if (published.is_partially_verified === true) {
        entry.sourceVerification = "partially-verified-on-blockscout";
        entry.sourceVerifiedAt = published.verified_at;
        entry.explorerConstructorArgumentsAvailable = typeof published.constructor_args === "string";
      }
      assert.equal(published.is_partially_verified, false, "Only partially verified");
      assert.equal(published.is_fully_verified, true, "Full verification pending");
      entry.sourceVerification = "verified-on-blockscout";
      entry.sourceVerifiedAt = published.verified_at;
      entry.explorerConstructorArgumentsAvailable = typeof published.constructor_args === "string";
      delete entry.sourceVerificationError;
      delete entry.verificationRequestStatus;
      console.log(`Confirmed fully verified source: ${entry.address}`);
    } catch (error) {
      failures.push(entry.address);
      if (entry.verificationRequestId) {
        try {
          const query = new URLSearchParams({ module: "contract", action: "checkverifystatus", guid: entry.verificationRequestId });
          const response = await fetch(`https://liteforge.explorer.caldera.xyz/api/?${query}`, { signal: AbortSignal.timeout(15_000) });
          const request = await response.json();
          if (request.status === "1" && typeof request.result === "string") {
            entry.verificationRequestStatus = request.result;
            if (request.result.startsWith("Fail")) {
              if (entry.sourceVerification !== "partially-verified-on-blockscout") {
                entry.sourceVerification = "verification-failed";
              }
              entry.sourceVerificationError = request.result;
            }
          }
        } catch {
          // Retain the last known request result if the explorer is unavailable.
        }
      }
      console.error(`Unconfirmed ${entry.address}: ${error.message.split("\n")[0]}`);
    }
  }
  record.sourceVerification = failures.length === 0 ? "verified-on-blockscout" : "verification-incomplete";
  record.sourceVerificationCheckedAt = new Date().toISOString();
  if (failures.length === 0) record.sourceVerifiedAt = record.sourceVerificationCheckedAt;
  writeFileSync(recordPath, `${JSON.stringify(record, null, 2)}\n`);
  assert.equal(failures.length, 0, `Verification incomplete for ${failures.join(", ")}`);
}
