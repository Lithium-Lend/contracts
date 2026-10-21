import assert from "node:assert/strict";
import fs from "node:fs";
import { fileURLToPath } from "node:url";

const root = new URL("../", import.meta.url);
const study = JSON.parse(fs.readFileSync(new URL("config/additional-market-study.json", root)));
const S = 10n ** 18n, INDEX = 10n ** 15n, YEAR = 31536000n, DAY = 86400n;
const min = (a, b) => a < b ? a : b;
const max = (a, b) => a > b ? a : b;
const pct = value => Number(value) / 1e16;
const fixed = value => Number(value.toFixed(6));
export function curveRate(c, side, u) {
  const k = BigInt(c.kink), low = min(u, k);
  return BigInt(c[`${side}Base`]) / YEAR + (BigInt(c[`${side}Low`]) / YEAR) * low / S
    + (BigInt(c[`${side}High`]) / YEAR) * (u - low) / S;
}

// Exact continuous quadratic bound after the constructor's per-second floors.
// Floors in getRate add a bounded two-unit tolerance, checked separately below.
function coverage(c) {
  const retained = BigInt(10000 - c.minRetainedBps), denominator = 10000n;
  const k = BigInt(c.kink), sb = BigInt(c.supplyBase) / YEAR;
  const sl = BigInt(c.supplyLow) / YEAR, sh = BigInt(c.supplyHigh) / YEAR;
  const bb = BigInt(c.borrowBase) / YEAR, bl = BigInt(c.borrowLow) / YEAR;
  const bh = BigInt(c.borrowHigh) / YEAR;
  const low = sb === 0n && sl * denominator <= bb * retained && bl >= 0n;
  const a = retained * bh;
  const b = retained * (bb * S + (bl - bh) * k) - denominator * sh * S;
  const d = -denominator * (sb * S * S + (sl - sh) * k * S);
  const high = a > 0n && (2n * a * k + b >= 0n
    ? a * k * k + b * k + d >= 0n : 4n * a * d - b * b >= 0n);
  assert(low && high, `${c.id}: continuous interest coverage`);
  const points = new Set(Array.from({length: 100001}, (_, i) => BigInt(i) * S / 100000n));
  for (const p of [0n, k, S, 2n*S, 10n*S]) for (const delta of [-1n,0n,1n]) if (p+delta >= 0n) points.add(p+delta);
  for (const u of points) {
    const income = curveRate(c, "borrow", u) * u / S;
    assert(curveRate(c, "supply", u) <= income * retained / denominator + 2n, `${c.id}: ${u}`);
  }
  return {continuousPass: true, gridPoints: points.size, roundingTolerancePerSecondUnits: 2,
    minRetainedInterestPercent: c.minRetainedBps / 100};
}

// One supplier and borrower, no cash flows after opening. Principal remains fixed;
// indices and utilization change each day exactly as in accruedInterestIndices.
export function accrue(c, decimals, utilizationBps, days, intervalDays = 1) {
  const unit = 10n ** BigInt(decimals);
  const supplyPrincipal = 1000n * unit, debtPrincipal = supplyPrincipal * BigInt(utilizationBps) / 10000n;
  let si = INDEX, bi = INDEX;
  const cash = supplyPrincipal - debtPrincipal;
  let firstLiquidationDay = null;
  for (let day = intervalDays; day <= days; day += intervalDays) {
    const supply = supplyPrincipal * si / INDEX, debt = debtPrincipal * bi / INDEX;
    const u = supply ? debt * S / supply : 0n;
    si += si * curveRate(c, "supply", u) * DAY * BigInt(intervalDays) / S;
    bi += bi * curveRate(c, "borrow", u) * DAY * BigInt(intervalDays) / S;
    if (si > 2n**64n-1n || bi > 2n**64n-1n) return {overflowDay:day};
    if (debtPrincipal && firstLiquidationDay === null && debtPrincipal * bi / INDEX * 6000n > debtPrincipal * 7000n) firstLiquidationDay = day;
  }
  const supply = supplyPrincipal * si / INDEX, debt = debtPrincipal * bi / INDEX;
  const reserves = cash + debt - supply;
  assert(reserves >= -2n, `${c.id}: accrual reserve loss`);
  return {supplied:fixed(Number(supply)/Number(unit)),debt:fixed(Number(debt)/Number(unit)),
    reserves:fixed(Number(reserves)/Number(unit)),utilizationPercent:fixed(pct(supply ? debt*S/supply : 0n)),
    availableCash:fixed(Number(cash)/Number(unit)),firstLiquidationDayAt60of70:firstLiquidationDay,
    raw:{supply:String(supply),debt:String(debt),reserves:String(reserves)}};
}

const riskRows = study.riskPairs.map(p => ({id:p.id,borrowPercent:p.borrowBps/100,liquidationPercent:p.liquidateBps/100,
  usdtLtcFallToLiquidationPercent:fixed(100*(1-p.borrowBps/p.liquidateBps)),
  nativeLtcRiseToLiquidationPercent:fixed(100*(p.liquidateBps/p.borrowBps-1)),
  nativeLtcRiseWith10PercentUsdcDepeg:fixed(100*(0.9*p.liquidateBps/p.borrowBps-1))}));

const shockInputs = {
  usdt: [["LTC -10%",.9,1],["LTC -15%",.85,1],["LTC -20%",.8,1],["LTC -30%",.7,1],["LTC -40%",.6,1],["LTC -50%",.5,1],
    ["USDT -10%",1,.9],["LTC -30%, USDT +5%",.7,1.05],["LTC -30%, USDT -10%",.7,.9]],
  zkltc: [["LTC +10%",1,1.1],["LTC +15%",1,1.15],["LTC +20%",1,1.2],["LTC +30%",1,1.3],["LTC +50%",1,1.5],["LTC +100%",1,2],
    ["USDC -5%",.95,1],["USDC -10%",.9,1],["USDC -20%",.8,1],["USDC -50%",.5,1],
    ["LTC +20%, USDC -10%",.9,1.2],["LTC +50%, USDC -10%",.9,1.5]]
};

// Scenario amounts normalized to $1,000 opening collateral and LTC=$100.
// A single delayed accrual is intentional; daily compounding is reported separately.
// Prices must be fresh at execution; stale feeds cause a revert rather than a sale.
export function liquidation({market, pair, curve, collateralMultiplier, baseMultiplier, delayHours, utilizationBps}) {
  const baseScale = market === "zkltc" ? S : 10n**6n;
  const priceScale = 10n**8n, openingBasePrice = market === "zkltc" ? 100n*priceScale : priceScale;
  const basePrice = openingBasePrice*BigInt(Math.round(baseMultiplier*10000))/10000n;
  const collateralValue = 1000n*priceScale*BigInt(Math.round(collateralMultiplier*10000))/10000n;
  const openingDebt = 1000n*priceScale*BigInt(pair.borrowBps)/10000n*baseScale/openingBasePrice;
  const rate = curveRate(curve,"borrow",BigInt(utilizationBps)*S/10000n);
  const bi = INDEX + INDEX*rate*BigInt(delayHours*3600)/S;
  const debt = openingDebt*bi/INDEX;
  const liquidatable = debt*basePrice/baseScale > collateralValue*BigInt(pair.liquidateBps)/10000n;
  const creditValue = collateralValue*BigInt(study.liquidationFactorBps)/10000n;
  const charge = max(debt, creditValue*baseScale/basePrice);
  const discountBps = BigInt(study.storefrontFactorBps)*BigInt(10000-study.liquidationFactorBps)/10000n;
  const proceeds = collateralValue*(10000n-discountBps)/10000n*baseScale/basePrice;
  const finalDelta = proceeds-charge;
  const amount = n => fixed(Number(n)/Number(baseScale));
  return {liquidatable, debt:amount(debt),ltvPercent:fixed(Number(debt*basePrice/baseScale)*100/Number(collateralValue)),
    raw:{debt:String(debt),charge:String(charge),credit:String(charge-debt),proceeds:String(proceeds),delta:String(finalDelta)},
    // Conditional amounts are zero until absorption is actually permitted.
    absorptionReserveDebit:liquidatable?amount(charge):0,
    borrowerSupplyCredit:liquidatable?amount(charge-debt):0,
    fullSaleProceeds:liquidatable?amount(proceeds):0,
    reserveDeltaAfterFullSale:liquidatable?amount(finalDelta):0,
    reserveDeltaUsdAtSale:liquidatable?fixed(Number(finalDelta)*Number(basePrice)/Number(baseScale)/Number(priceScale)):0,
    initialReserveNeededToAvoidDeficitBeforeSale:liquidatable?amount(charge):0,
    initialReserveNeededToAvoidDeficitAfterFullSale:liquidatable?amount(max(0n,-finalDelta)):0};
}

export function simulate() {
  const curves = study.curves.map(c=>({id:c.id,...coverage(c),samples:[0,10,50,75,80,90,95,100,110].map(u=>{
    const utilization=BigInt(u)*S/100n;
    const supply=curveRate(c,"supply",utilization),borrow=curveRate(c,"borrow",utilization);
    return {utilizationPercent:u,supplyAprPercent:fixed(pct(supply*YEAR)),borrowAprPercent:fixed(pct(borrow*YEAR)),
      annualNetInterestPer1000BaseAtFixedUtilization:fixed(Number((borrow*utilization/S-supply)*YEAR)/1e15)};
  })}));
  const accrual=[];
  for (const c of study.curves) for(const decimals of [6,18]) for(const u of [0,1000,5000,8000,9000,9500,10000]) for(const days of [1,7,30,90,365]) {
    accrual.push({curve:c.id,decimals,startingUtilizationPercent:u/100,days,daily:accrue(c,decimals,u,days),idle:accrue(c,decimals,u,days,days)});
  }
  const shocks=[];
  for(const [market, scenarios] of Object.entries(shockInputs)) for(const pair of study.riskPairs) for(const c of study.curves)
    for(const [scenario,collateralMultiplier,baseMultiplier] of scenarios) for(const delayHours of [0,1,24,168]) for(const utilizationBps of [9000,10000]) {
      shocks.push({market,pair:pair.id,curve:c.id,scenario,delayHours,utilizationPercent:utilizationBps/100,
        ...liquidation({market,pair,curve:c,collateralMultiplier,baseMultiplier,delayHours,utilizationBps})});
    }
  return {assumptions:{openingCollateralUsd:1000,openingLtcUsd:100,
    collateralSaleDiscountPercent:6,fullSaleAssumption:"Fresh unchanged prices, a funded buyer, all collateral sold while sale gate permits. This is recovery capacity, not guaranteed execution.",
    reserveTarget:"A sale threshold, not funded reserves or a borrowing cap.",
    delay:"No liquidation during the stated gap. Feed freshness is a separate execution requirement.",
    markets:"Faucet tokens are unbacked test assets. This model does not establish issuer, bridge, DEX, or mainnet safety.",
    stochastic:"Deterministic stresses, no historical probabilities, expected loss estimate, or globally optimal configuration."},
    riskRows,curves,accrual,shocks,
    buyerEconomics:[0,2,5,6,8].map(cost=>({executionCostPercentOfOracleCollateral:cost,grossDiscountPercent:6,remainingEdgePercent:6-cost})),
    liquidationDelayBudget:study.riskPairs.map(p=>({pair:p.id,
      additionalCollateralFallFromLiquidationThresholdToSaleShortfallPercent:fixed(100*(1-p.liquidateBps/9400)),
      additionalBaseRiseFromLiquidationThresholdToSaleShortfallPercent:fixed(100*(9400/p.liquidateBps-1))}))};
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const result=simulate();
  const output=new URL("research/additional-market-results.json",root);
  if(process.argv.includes("--write")) fs.writeFileSync(output,JSON.stringify(result,null,2)+"\n");
  if(process.argv.includes("--write") || process.argv.includes("--check")) {
    const fixtures = {accrual:[],liquidation:[]};
    study.curves.forEach((c,curveIndex)=>{
      for(const decimals of [6,18]) for(const u of [1000,9000,10000]) for(const interval of [1,365]) {
        const actual=accrue(c,decimals,u,365,interval);
        assert(!actual.overflowDay);
        fixtures.accrual.push({curve:curveIndex,decimals,utilizationBps:u,intervalDays:interval,days:365,...actual.raw});
      }
    });
    study.riskPairs.forEach((pair,pairIndex)=>{
      for(const market of ["usdt","zkltc"]) for(const [cm,bm] of market==="usdt"?[[.7,1],[.5,1],[.7,1.05]]:[[1,1.5],[1,2],[.9,1.2]]) {
        const actual=liquidation({market,pair,curve:study.curves[1],collateralMultiplier:cm,baseMultiplier:bm,delayHours:168,utilizationBps:10000});
        fixtures.liquidation.push({pair:pairIndex,native:market==="zkltc",collateralBps:Math.round(cm*10000),baseBps:Math.round(bm*10000),liquidatable:actual.liquidatable,...actual.raw});
      }
    });
    const fixturePath=new URL("config/additional-market-model-fixtures.json",root);
    if(process.argv.includes("--write")) fs.writeFileSync(fixturePath,JSON.stringify(fixtures,null,2)+"\n");
    else assert.deepEqual(JSON.parse(fs.readFileSync(fixturePath)),fixtures,"Contract fixtures must match the independent model");
  }
  console.log(JSON.stringify({riskRows:result.riskRows,curves:result.curves,
    accrualPaths:result.accrual.length,shockCases:result.shocks.length,liquidationDelayBudget:result.liquidationDelayBudget},null,2));
}
