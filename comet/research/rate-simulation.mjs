import fs from "node:fs";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";

// Read-only simulation. Integer operations mirror constructor truncation and
// getSupplyRate/getBorrowRate. Accrual itself is tested in Foundry separately.
const configDir = new URL("../config/", import.meta.url);
const study = JSON.parse(fs.readFileSync(new URL("rate-simulation.json", configDir)));
const baseline = JSON.parse(fs.readFileSync(new URL(study.baseline, configDir))).environment;
const selected = JSON.parse(fs.readFileSync(new URL(study.selectedConfiguration, configDir))).environment;
const deployment = JSON.parse(fs.readFileSync(new URL("../deployments/liteforge.json", configDir)));
assert.equal(createHash("sha256").update(JSON.stringify(baseline)).digest("hex"), deployment.configurationEnvironmentSha256,
  "Historical deployment inputs must remain unchanged");
assert.deepEqual(Object.keys(selected).sort(), Object.keys(baseline).sort(), "No input may be added or dropped");
assert.deepEqual(Object.keys(selected).filter((key) => selected[key] !== baseline[key]), ["COMET_BORROW_RATE_BASE"],
  "Only the borrowing base may change");
assert.equal(selected.COMET_BORROW_RATE_BASE, "36000000000000000");
assert.deepEqual(selected, { ...baseline, ...study.candidates[study.preferredCandidateIndex].overrides },
  "The selected configuration must match the tested candidate");
const scale = 10n ** 18n;
const year = 31536000n;

function curve(env, side) {
  const get = (suffix) => BigInt(env[`COMET_${side}_${suffix}`]);
  return { kink: get("KINK"), base: get("RATE_BASE") / year, low: get("SLOPE_LOW") / year, high: get("SLOPE_HIGH") / year };
}
function rate(c, u) {
  const lowU = u < c.kink ? u : c.kink;
  return c.base + c.low * lowU / scale + c.high * (u - lowU) / scale;
}
function apr(value) { return Number(value) * Number(year) / 1e16; }

const results = study.candidates.map((candidate) => {
  const env = { ...baseline, ...candidate.overrides };
  const supply = curve(env, "SUPPLY");
  const borrow = curve(env, "BORROW");
  const allowsSubsidy = candidate.allowsSubsidy === true;
  const boundaryOnly = allowsSubsidy || candidate.id.endsWith("-boundary");
  const marginNumerator = boundaryOnly ? 1n : 9n;
  const marginDenominator = boundaryOnly ? 1n : 10n;

  // Continuous, unrounded proof for ALL u, not just a sampled grid:
  // below the common kink, sLow <= retained*bBase and bLow >= 0 suffice.
  // Above it, retained income minus expense is quadratic. Check its minimum
  // at the kink or at its vertex, including a dip between sampled points.
  const lowBound = supply.base === 0n && supply.low * marginDenominator <= borrow.base * marginNumerator;
  const a = marginNumerator * borrow.high;
  const b = marginNumerator * (borrow.base * scale + (borrow.low - borrow.high) * borrow.kink)
    - marginDenominator * supply.high * scale;
  const c = -marginDenominator * (supply.base * scale * scale + (supply.low - supply.high) * supply.kink * scale);
  const k = supply.kink;
  const highBound = a > 0n && (2n * a * k + b >= 0n
    ? a * k * k + b * k + c >= 0n
    : 4n * a * c - b * b >= 0n);
  const analyticalPass = supply.kink === borrow.kink && lowBound && highBound;
  assert.equal(analyticalPass, !allowsSubsidy, `${candidate.id}: unexpected continuous bound result`);
  if (candidate.id === "supply-preserving-half-increase") {
    assert(highBound, "The half-increase comparison must cover interest above the kink");
    // Below the kink, the quadratic minimum is -(sLow - bBase)^2 / (4*bLow).
    // Round this loss upwards and include two per-second floor units. This
    // proves the fixed-balance bound between grid points as well.
    const gap = supply.low - borrow.base;
    assert(gap > 0n && gap * scale < 2n * borrow.low * supply.kink, "Minimum must be inside the low branch");
    const divisor = 4n * borrow.low;
    const worstLossRateBound = (gap * gap + divisor - 1n) / divisor + 2n;
    assert(worstLossRateBound * year < scale / 1000n, "Continuous half-increase subsidy bound failed");
  }

  let negativePoints = 0;
  let worst = { u: 0n, spread: 0n };
  // 100,001 points over 0..100%, plus single-wei neighborhoods and >100% stress.
  const points = new Set(Array.from({ length: 100001 }, (_, i) => BigInt(i) * scale / 100000n));
  for (const center of [0n, 1n, supply.kink, scale, 2n * scale, 10n * scale]) {
    for (const offset of [-1n, 0n, 1n]) if (center + offset >= 0n) points.add(center + offset);
  }
  for (const u of points) {
    const income = rate(borrow, u) * u / scale;
    const expense = rate(supply, u);
    const spread = income - expense;
    if (u <= scale && spread < 0n) negativePoints++;
    if (u <= scale && spread < worst.spread) worst = { u, spread };
    if (!allowsSubsidy) {
      // Floors can move the inequality by up to two 1e-18/second rate units.
      assert(expense <= income * marginNumerator / marginDenominator + 2n, `${candidate.id}: rounding bound at ${u}`);
    }
  }
  const samples = [0, 10, 25, 50, 75, 80, 90, 95, 100].map((percent) => {
    const u = BigInt(percent) * scale / 100n;
    const s = rate(supply, u), b = rate(borrow, u);
    return {
      utilizationPercent: percent,
      supplyAprPercent: apr(s),
      borrowAprPercent: apr(b),
      // Fixed utilization and supply illustration. Not a compounded forecast.
      annualNetInterestPer1000Usdc: apr(b * u / scale - s) * 10,
    };
  });
  return {
    id: candidate.id, overrides: candidate.overrides, allowsSubsidy, analyticalPass,
    lowBranchBreakEvenUtilizationPercent: Math.max(0, Number(supply.low - borrow.base) / Number(borrow.low) * 100),
    negativeGridPoints: negativePoints,
    worstAnnualNetPer1000Usdc: apr(worst.spread) * 10,
    worstUtilizationPercent: Number(worst.u) / 1e16,
    samples,
  };
});
assert(results[0].negativeGridPoints > 0, "Baseline must reproduce the subsidy");
const selectedResult = results[study.preferredCandidateIndex];
assert(selectedResult.analyticalPass, "Selected rates must cover supplier interest continuously");
assert.equal(selectedResult.allowsSubsidy, false, "Selected policy must not allow an interest subsidy");
assert.equal(selectedResult.negativeGridPoints, 0, "Selected rates must not have a sampled deficit");
const halfIncrease = results.find((result) => result.id === "supply-preserving-half-increase");
assert(halfIncrease.negativeGridPoints > 0, "The unselected half-increase must still reproduce its deficit");
assert(halfIncrease.lowBranchBreakEvenUtilizationPercent > 37.79
  && halfIncrease.lowBranchBreakEvenUtilizationPercent < 37.81, "Unexpected half-increase break-even point");
assert(halfIncrease.worstAnnualNetPer1000Usdc > -1 && halfIncrease.worstAnnualNetPer1000Usdc < -0.98,
  "Do not hide the unselected half-increase subsidy");
console.log(JSON.stringify({
  status: study.status,
  assumption: study.objective,
  preferredCandidate: study.candidates[study.preferredCandidateIndex].id,
  roundingToleranceRateUnits: 2,
  results,
}, null, 2));
