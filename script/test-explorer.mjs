import test from 'node:test';
import assert from 'node:assert/strict';
import { classifyVerification, inspectVerification } from './lib/explorer-assurance.mjs';

test('full assurance requires published source and explicit consistent full flags', () => {
  const source = { source_code: 'contract A {}', is_verified: true, is_fully_verified: true, is_partially_verified: false };
  assert.equal(classifyVerification(source), 'full');
  assert.equal(classifyVerification({ ...source, is_partially_verified: true }), 'partial');
  assert.equal(classifyVerification({ ...source, is_fully_verified: undefined }), 'published-unclassified');
  assert.equal(classifyVerification({ ...source, source_code: '' }), 'unknown');
});
test('legacy publication and address flags cannot establish full verification', () => {
  assert.equal(classifyVerification(undefined, { is_contract: true, is_verified: true }), 'unknown');
  assert.equal(classifyVerification(undefined, undefined, { status: '1', result: [{ SourceCode: 'contract A {}' }] }), 'published-unclassified');
  assert.equal(classifyVerification(undefined, { is_contract: true, is_verified: false }), 'unverified');
});
test('explorer failures remain unknown and never become verified or unverified by inference', async () => {
  const result = await inspectVerification({ address: '0x01', role: 'test' }, async () => ({ status: 500, ok: false }));
  assert.equal(result.status, 'unknown');
  assert.deepEqual(result.httpStatus, { source: 500, address: 500, legacy: 500 });
});
