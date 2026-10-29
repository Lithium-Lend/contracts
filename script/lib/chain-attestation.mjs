import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';

export const ZERO = `0x${'0'.repeat(40)}`;
const READ_METHODS = new Set(['eth_chainId', 'eth_getBlockByNumber', 'eth_getCode', 'eth_getStorageAt', 'eth_call']);
export const IMPLEMENTATION_SLOT = '0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc';
export const ADMIN_SLOT = '0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103';
export const same = (a, b) => String(a).toLowerCase() === String(b).toLowerCase();
export const json = value => JSON.stringify(value, (_, v) => typeof v === 'bigint' ? String(v) : v, 2) + '\n';

export function cast(args, input) {
  const result = spawnSync('cast', args, { input, encoding: 'utf8', windowsHide: true, timeout: 15000, maxBuffer: 1024 * 1024 });
  if (result.error || result.status !== 0) throw new Error(`cast ${args[0]} failed`);
  return result.stdout.trim();
}

export function codeHash(code) {
  assert.match(code, /^0x(?:[0-9a-fA-F]{2})+$/, 'Contract runtime must not be empty');
  return cast(['keccak'], code);
}

export function word(data, index = 0) {
  assert.match(data, /^0x(?:[0-9a-fA-F]{64})+$/, 'Malformed ABI response');
  assert(data.length >= 2 + (index + 1) * 64, 'Truncated ABI response');
  return BigInt(`0x${data.slice(2 + index * 64, 66 + index * 64)}`);
}

export function address(data, index = 0) {
  const value = word(data, index);
  assert(value < 2n ** 160n, 'Non-canonical ABI address');
  return `0x${value.toString(16).padStart(40, '0')}`;
}

export function abiString(data) {
  assert.equal(word(data), 32n, 'Unexpected string offset');
  const size = word(data, 1);
  assert(size <= 256n && data.length >= 130 + Number(size) * 2, 'Invalid string length');
  return Buffer.from(data.slice(130, 130 + Number(size) * 2), 'hex').toString('utf8');
}

export function rpcClient(url, fetcher = fetch) {
  const parsed = new URL(url);
  assert(['http:', 'https:'].includes(parsed.protocol), 'HTTP RPC required');
  let id = 0;
  return async (method, params) => {
    assert(READ_METHODS.has(method), 'Only read-only RPC methods are permitted');
    const requestId = ++id;
    let last;
    for (let attempt = 0; attempt < 3; attempt++) {
      try {
        const response = await fetcher(url, {
          method: 'POST', headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ jsonrpc: '2.0', id: requestId, method, params }), signal: AbortSignal.timeout(15000),
        });
        if (!response.ok) throw new Error(`RPC HTTP ${response.status}`);
        const payload = await response.json();
        assert.equal(payload.id, requestId, 'RPC response ID mismatch');
        if (payload.error || payload.result == null) throw new Error(`RPC ${method} failed`);
        return payload.result;
      } catch (error) { last = error; }
    }
    // Do not include a credential-bearing RPC URL or raw response in logs.
    throw new Error(`Read failed: ${method}`, { cause: last });
  };
}

export function evaluateMarketHealth(market, policy) {
  const alerts = [];
  const total = BigInt(market.collateralSupply), cap = BigInt(market.supplyCap);
  const supply = BigInt(market.totalSupply), cash = BigInt(market.baseCash);
  assert(cap > 0n && supply >= 0n && cash >= 0n);
  const capBps = total * 10000n / cap;
  if (total >= cap) alerts.push({ level: 'critical', code: 'collateral-cap-full' });
  else if (capBps >= BigInt(policy.capCriticalBps)) alerts.push({ level: 'critical', code: 'collateral-cap-near-full' });
  else if (capBps >= BigInt(policy.capWarningBps)) alerts.push({ level: 'warning', code: 'collateral-cap-high' });
  if (supply > 0n && cash * 10000n / supply < BigInt(policy.minimumCashBps)) alerts.push({ level: 'critical', code: 'base-cash-low' });
  if (BigInt(market.reserves) < 0n) alerts.push({ level: 'critical', code: 'negative-reserves' });
  return alerts.map(alert => ({ ...alert, market: market.id }));
}

export function compareSnapshot(snapshot, expected) {
  const errors = [], alerts = [];
  const compare = (label, actual, target) => {
    const equal = /^0x[0-9a-f]+$/i.test(String(target)) ? same(actual, target) : String(actual) === String(target);
    if (!equal) errors.push(`${label}: expected ${target}, observed ${actual}`);
  };
  compare('chainId', snapshot.chainId, expected.chainId);
  compare('component count', snapshot.components.length, expected.components.length);
  compare('market count', snapshot.markets.length, expected.markets.length);
  compare('oracle count', snapshot.oracles.length, expected.oracles.length);
  compare('adapter count', snapshot.adapters.length, expected.adapters.length);
  for (const want of expected.components) {
    const actual = snapshot.components.find(c => same(c.address, want.address));
    compare(`runtime ${want.role} ${want.address}`, actual?.codeHash, want.codeHash);
    if (want.owner) compare(`owner ${want.address}`, actual?.owner, want.owner);
  }
  for (const want of expected.markets) {
    const actual = snapshot.markets.find(m => m.id === want.id);
    if (!actual) { errors.push(`Missing market ${want.id}`); continue; }
    for (const field of ['proxy', 'implementation', 'admin', 'governor', 'pauseGuardian', 'baseToken', 'baseTokenPriceFeed', 'extensionDelegate', 'assetList', 'collateralToken', 'collateralPriceFeed', 'supplyCap', 'borrowCollateralFactor', 'liquidateCollateralFactor', 'liquidationFactor']) {
      compare(`${want.id}.${field}`, actual[field], want[field]);
    }
    for (const [name, value] of Object.entries(actual.paused)) if (value) alerts.push({ level: 'warning', code: `${name}-paused`, market: want.id });
    alerts.push(...evaluateMarketHealth(actual, expected.healthPolicy));
  }
  for (const want of expected.oracles) {
    const actual = snapshot.oracles.find(o => same(o.address, want.address));
    if (!actual) { errors.push(`Missing oracle ${want.address}`); continue; }
    for (const field of ['owner', 'pairKey', 'diaOracleAddress', 'decimals']) compare(`oracle ${want.address}.${field}`, actual[field], want[field]);
    const { answer, updatedAt, roundId, answeredInRound } = actual;
    if (BigInt(answer) <= 0n || Number(updatedAt) <= 0 || Number(updatedAt) > snapshot.timestamp || snapshot.timestamp - Number(updatedAt) > want.maxStaleness || BigInt(answeredInRound) < BigInt(roundId)) {
      errors.push(`Invalid or stale oracle round ${want.address}`);
    }
  }
  for (const want of expected.adapters) {
    const actual = snapshot.adapters.find(a => same(a.address, want.address));
    for (const field of ['source', 'sourceDecimals', 'maxStaleness']) compare(`adapter ${want.address}.${field}`, actual?.[field], want[field]);
    if (!actual?.validRound) errors.push(`Adapter cannot provide a valid round ${want.address}`);
  }
  return { errors, alerts, stateMatches: errors.length === 0, criticalHealthAlerts: alerts.filter(a => a.level === 'critical').length };
}

export async function captureSnapshot(rpc, expected, blockTag = 'latest') {
  const chainId = Number(BigInt(await rpc('eth_chainId', [])));
  assert.equal(chainId, expected.chainId, 'Wrong chain');
  const header = await rpc('eth_getBlockByNumber', [blockTag, false]);
  assert.match(header.hash, /^0x[0-9a-fA-F]{64}$/);
  const block = header.number, timestamp = Number(BigInt(header.timestamp));
  const snapshot = { schemaVersion: 1, observedAt: new Date().toISOString(), chainId, blockNumber: Number(BigInt(block)), blockHash: header.hash, timestamp, components: [], markets: [], oracles: [], adapters: [] };
  const data = new Map();
  const call = async (to, signature, args = []) => {
    const key = `${to.toLowerCase()}:${signature}:${args.join(',')}`;
    if (!data.has(key)) data.set(key, await rpc('eth_call', [{ to, data: cast(['calldata', signature, ...args.map(String)]) }, block]));
    return data.get(key);
  };
  for (const component of expected.components) {
    const item = { address: component.address, role: component.role, codeHash: codeHash(await rpc('eth_getCode', [component.address, block])) };
    if (component.owner) item.owner = address(await call(component.address, 'owner()'));
    snapshot.components.push(item);
  }
  for (const market of expected.markets) {
    const proxy = market.proxy;
    const item = { id: market.id, proxy };
    item.implementation = address(await rpc('eth_getStorageAt', [proxy, IMPLEMENTATION_SLOT, block]));
    item.admin = address(await rpc('eth_getStorageAt', [proxy, ADMIN_SLOT, block]));
    for (const name of ['governor', 'pauseGuardian', 'baseToken', 'baseTokenPriceFeed', 'extensionDelegate', 'assetList']) item[name] = address(await call(proxy, `${name}()`));
    const info = await call(proxy, 'getAssetInfo(uint8)', [0]);
    item.collateralToken = address(info, 1); item.collateralPriceFeed = address(info, 2);
    for (const [i, name] of [[4, 'borrowCollateralFactor'], [5, 'liquidateCollateralFactor'], [6, 'liquidationFactor'], [7, 'supplyCap']]) item[name] = String(word(info, i));
    item.collateralSupply = String(word(await call(proxy, 'totalsCollateral(address)', [item.collateralToken])));
    for (const name of ['totalSupply', 'totalBorrow']) item[name] = String(word(await call(proxy, `${name}()`)));
    const reserves = word(await call(proxy, 'getReserves()'));
    item.reserves = String(reserves >= 2n ** 255n ? reserves - 2n ** 256n : reserves);
    item.baseCash = String(word(same(item.baseToken, ZERO) ? await call(proxy, 'accountedNative()') : await call(item.baseToken, 'balanceOf(address)', [proxy])));
    item.paused = {};
    for (const name of ['Supply', 'Transfer', 'Withdraw', 'Absorb', 'Buy']) {
      const flag = word(await call(proxy, `is${name}Paused()`));
      assert(flag <= 1n, 'Invalid ABI boolean'); item.paused[name.toLowerCase()] = flag === 1n;
    }
    snapshot.markets.push(item);
  }
  for (const oracle of expected.oracles) {
    const to = oracle.address, round = await call(to, 'latestRoundData()');
    const answer = word(round, 1);
    snapshot.oracles.push({ address: to, owner: address(await call(to, 'owner()')), diaOracleAddress: address(await call(to, 'diaOracleAddress()')), pairKey: abiString(await call(to, 'pairKey()')), decimals: Number(word(await call(to, 'decimals()'))), answer: String(answer >= 2n ** 255n ? answer - 2n ** 256n : answer), roundId: String(word(round)), updatedAt: String(word(round, 3)), answeredInRound: String(word(round, 4)) });
  }
  for (const adapter of expected.adapters) {
    const to = adapter.address;
    const item = { address: to, source: address(await call(to, 'source()')), sourceDecimals: Number(word(await call(to, 'sourceDecimals()'))), maxStaleness: String(word(await call(to, 'maxStaleness()'))), validRound: false };
    try {
      const r = await call(to, 'latestRoundData()');
      item.validRound = word(r, 1) > 0n && word(r, 1) < 2n ** 255n && word(r, 3) > 0n && word(r, 3) <= BigInt(timestamp) && BigInt(timestamp) - word(r, 3) <= BigInt(item.maxStaleness) && word(r, 4) >= word(r);
    } catch { /* A failed round is a failed assertion, never a skipped feed. */ }
    snapshot.adapters.push(item);
  }
  assert.equal((await rpc('eth_getBlockByNumber', [block, false])).hash, header.hash, 'Snapshot block changed');
  return snapshot;
}
