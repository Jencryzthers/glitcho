import crypto from 'node:crypto';

function chunk(input, size) {
  const output = [];
  for (let index = 0; index < input.length; index += size) {
    output.push(input.slice(index, index + size));
  }
  return output;
}

export function generateLicenseKey() {
  const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  const bytes = crypto.randomBytes(20);
  let randomPart = '';
  for (const value of bytes) {
    randomPart += alphabet[value % alphabet.length];
  }
  const checksum = crypto.createHash('sha256').update(randomPart).digest('hex').slice(0, 6).toUpperCase();
  const grouped = chunk(randomPart, 5).join('-');
  return `PRO-LIFETIME-${grouped}-${checksum}`;
}

export function canonicalPayload({ valid, expires_at, entitlements }) {
  const entitlementString = Array.isArray(entitlements) ? [...entitlements].sort().join(',') : '';
  return `valid=${valid ? 'true' : 'false'};expires_at=${expires_at || ''};entitlements=${entitlementString}`;
}

export function signPayload(payload, privateKeyPEM) {
  if (!privateKeyPEM || !privateKeyPEM.trim()) {
    return 'compat-signature-placeholder';
  }
  const signature = crypto.sign('sha256', Buffer.from(payload, 'utf8'), privateKeyPEM);
  return signature.toString('base64');
}
