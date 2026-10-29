import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { compareSnapshot, evaluateMarketHealth, word, address, abiString, rpcClient } from './lib/chain-attestation.mjs';

const expected = JSON.parse(readFileSync(new URL('../comet/config/liteforge-attestation.json', import.meta.url)));
function fixture() {
  return {
    chainId: 4441, timestamp: 1800000000,
    components: structuredClone(expected.components),
    markets: expected.markets.map(m => ({ ...m, collateralSupply: '1', totalSupply: '10000', totalBorrow: '0', baseCash: '10000', reserves: '0', paused: {} })),
    oracles: expected.oracles.map(o => ({ ...o, answer: '100000000', updatedAt: '1800000000', roundId: '5', answeredInRound: '5' })),
    adapters: expected.adapters.map(a => ({ ...a, validRound: true })),
  };
}
test('approved state is accepted without hiding current testnet trust', () => {
  const verdict = compareSnapshot(fixture(), expected);
  assert.equal(verdict.stateMatches, true);
  assert.equal(expected.acceptedTestnetTrust.productionReady, false);
});
for (const field of ['implementation', 'admin', 'governor', 'pauseGuardian', 'baseTokenPriceFeed', 'assetList', 'supplyCap']) {
  test(`changed ${field} fails attestation`, () => {
    const snapshot = fixture();
    snapshot.markets[0][field] = field === 'supplyCap' ? String(BigInt(snapshot.markets[0][field]) + 1n) : 'unexpected';
    assert.equal(compareSnapshot(snapshot, expected).stateMatches, false);
  });
}
for (const field of ['owner', 'pairKey', 'diaOracleAddress', 'decimals']) {
  test(`changed oracle ${field} fails even with a fresh valid price`, () => {
    const snapshot = fixture(); snapshot.oracles[0][field] = 'unexpected';
    assert.equal(compareSnapshot(snapshot, expected).stateMatches, false);
  });
}
test('unexpected code or missing components fail', () => {
  const snapshot = fixture(); snapshot.components[0].codeHash = `0x${'0'.repeat(64)}`;
  assert.equal(compareSnapshot(snapshot, expected).stateMatches, false);
  snapshot.components.shift(); assert.equal(compareSnapshot(snapshot, expected).stateMatches, false);
});
test('oracle pair keys are case-sensitive even when addresses are not', () => {
  const snapshot = fixture();
  snapshot.oracles[0].pairKey = snapshot.oracles[0].pairKey.toLowerCase();
  assert.notEqual(snapshot.oracles[0].pairKey, expected.oracles[0].pairKey);
  assert.equal(compareSnapshot(snapshot, expected).stateMatches, false);
});
for (const [field, value] of [['answer', '-1'], ['answer', '0'], ['updatedAt', '0'], ['updatedAt', '1800000001'], ['updatedAt', '1799996399'], ['answeredInRound', '4']]) {
  test(`oracle ${field}=${value} fails`, () => {
    const snapshot = fixture(); snapshot.oracles[0][field] = value;
    assert.equal(compareSnapshot(snapshot, expected).stateMatches, false);
  });
}
test('freshness boundary is inclusive and failed adapter rounds are never skipped', () => {
  const snapshot = fixture(); snapshot.oracles[0].updatedAt = String(snapshot.timestamp - 3600);
  assert.equal(compareSnapshot(snapshot, expected).stateMatches, true);
  snapshot.adapters[0].validRound = false;
  assert.equal(compareSnapshot(snapshot, expected).stateMatches, false);
});
test('cap and cash alerts are independent of integrity assertions', () => {
  const market = { id: 'native', collateralSupply: '900', supplyCap: '1000', totalSupply: '10000', baseCash: '99', reserves: '-1' };
  assert.deepEqual(evaluateMarketHealth(market, expected.healthPolicy).map(a => a.code), ['collateral-cap-near-full', 'base-cash-low', 'negative-reserves']);
  market.collateralSupply = '1000'; assert.equal(evaluateMarketHealth(market, expected.healthPolicy)[0].code, 'collateral-cap-full');
  market.collateralSupply = '700'; market.baseCash = '100'; market.reserves = '0';
  assert.deepEqual(evaluateMarketHealth(market, expected.healthPolicy).map(a => a.code), ['collateral-cap-high']);
});
test('ABI decoding rejects truncated and non-canonical values', () => {
  assert.throws(() => word('0x01'));
  assert.throws(() => word(`0x${'0'.repeat(64)}`, 1));
  assert.throws(() => address(`0x${'f'.repeat(64)}`));
  assert.throws(() => abiString(`0x${'0'.repeat(128)}`));
});
test('RPC client cannot broadcast or log secrets on failure', async () => {
  let calls = 0;
  const rpc = rpcClient('https://example.invalid/private-rpc-token', async () => { calls++; throw new Error('private-rpc-token'); });
  await assert.rejects(rpc('eth_sendRawTransaction', []), /read-only/);
  assert.equal(calls, 0);
  await assert.rejects(rpc('eth_chainId', []), error => error.message === 'Read failed: eth_chainId');
  assert.equal(calls, 3);
});
test('RPC errors and mismatched responses fail instead of producing empty successful state', async () => {
  const rpc = rpcClient('https://example.invalid', async () => ({ ok: true, json: async () => ({ id: 99, result: '0x1159' }) }));
  await assert.rejects(rpc('eth_chainId', []));
});
