import test from 'node:test';
import assert from 'node:assert/strict';
import { signSession, verifySession } from '../src/lib/security.js';

test('verifySession returns payload for valid signed session', () => {
  const token = signSession({ uid: 'usr_1', role: 'customer', exp: Date.now() + 10_000 }, 'secret');
  const decoded = verifySession(token, 'secret');
  assert.equal(decoded.uid, 'usr_1');
  assert.equal(decoded.role, 'customer');
});

test('verifySession rejects expired session', () => {
  const token = signSession({ uid: 'usr_1', role: 'customer', exp: Date.now() - 1 }, 'secret');
  const decoded = verifySession(token, 'secret');
  assert.equal(decoded, null);
});
