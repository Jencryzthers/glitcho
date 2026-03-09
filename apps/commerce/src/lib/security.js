import crypto from 'node:crypto';

export function sha256(input) {
  return crypto.createHash('sha256').update(String(input), 'utf8').digest('hex');
}

export function randomToken(bytes = 32) {
  return crypto.randomBytes(bytes).toString('base64url');
}

function hmacSignature(value, secret) {
  return crypto.createHmac('sha256', secret).update(value).digest('base64url');
}

export function signSession(payload, secret) {
  const base = Buffer.from(JSON.stringify(payload), 'utf8').toString('base64url');
  const sig = hmacSignature(base, secret);
  return `${base}.${sig}`;
}

export function verifySession(token, secret) {
  if (!token || typeof token !== 'string') {
    return null;
  }
  const [base, sig] = token.split('.');
  if (!base || !sig) {
    return null;
  }
  const expected = hmacSignature(base, secret);
  const sigBuffer = Buffer.from(sig);
  const expectedBuffer = Buffer.from(expected);
  if (sigBuffer.length !== expectedBuffer.length) {
    return null;
  }
  if (!crypto.timingSafeEqual(sigBuffer, expectedBuffer)) {
    return null;
  }
  try {
    const decoded = JSON.parse(Buffer.from(base, 'base64url').toString('utf8'));
    if (!decoded || typeof decoded !== 'object') {
      return null;
    }
    if (typeof decoded.exp !== 'number' || decoded.exp < Date.now()) {
      return null;
    }
    return decoded;
  } catch {
    return null;
  }
}

export function hashIP(ipAddress) {
  return sha256(String(ipAddress || 'unknown')).slice(0, 32);
}
