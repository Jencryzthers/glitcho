import test from 'node:test';
import assert from 'node:assert/strict';
import { generateLicenseKey, canonicalPayload } from '../src/lib/license.js';

test('generateLicenseKey produces pro-lifetime format', () => {
  const key = generateLicenseKey();
  assert.match(key, /^PRO-LIFETIME-[A-Z0-9]{5}(?:-[A-Z0-9]{5}){3}-[A-F0-9]{6}$/);
});

test('canonicalPayload sorts entitlements deterministically', () => {
  const value = canonicalPayload({
    valid: true,
    expires_at: '2027-01-01T00:00:00Z',
    entitlements: ['recording', 'video_pro']
  });

  const expected = 'valid=true;expires_at=2027-01-01T00:00:00Z;entitlements=recording,video_pro';
  assert.equal(value, expected);
});
