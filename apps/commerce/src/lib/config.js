import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { config as loadDotEnv } from 'dotenv';

loadDotEnv();

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const projectRoot = path.resolve(__dirname, '..', '..');

function resolveDataDir() {
  const preferred = process.env.DATA_DIR || '/data';
  try {
    fs.mkdirSync(preferred, { recursive: true });
    return preferred;
  } catch {
    const fallback = path.resolve(projectRoot, 'data');
    fs.mkdirSync(fallback, { recursive: true });
    return fallback;
  }
}

const dataDir = resolveDataDir();

function parseList(value) {
  return String(value || '')
    .split(',')
    .map(item => item.trim().toLowerCase())
    .filter(Boolean);
}

export const appConfig = {
  nodeEnv: process.env.NODE_ENV || 'production',
  port: Number(process.env.PORT || 8080),
  publicBaseURL: (process.env.PUBLIC_BASE_URL || '').trim(),
  appName: (process.env.APP_NAME || 'Glitcho').trim(),
  proPriceCents: Number(process.env.PRO_PRICE_CENTS || 2900),
  proCurrency: (process.env.PRO_CURRENCY || 'usd').trim().toLowerCase(),
  downloadURL: (process.env.DOWNLOAD_URL || '').trim(),
  downloadFilePath: (process.env.DOWNLOAD_FILE_PATH || path.join(dataDir, 'Glitcho.zip')).trim(),
  githubRepoOwner: (process.env.GITHUB_REPO_OWNER || 'Jencryzthers').trim(),
  githubRepoName: (process.env.GITHUB_REPO_NAME || 'glitcho').trim(),
  githubToken: (process.env.GITHUB_TOKEN || '').trim(),
  githubReleaseAPIBaseURL: (process.env.GITHUB_RELEASE_API_BASE_URL || 'https://api.github.com').trim(),
  githubReleaseAssetPattern: (process.env.GITHUB_RELEASE_ASSET_PATTERN || '').trim(),
  githubReleaseCacheTTLSeconds: Number(process.env.GITHUB_RELEASE_CACHE_TTL_SECONDS || 300),
  dataDir,
  storePath: (process.env.STORE_PATH || path.join(dataDir, 'commerce-store.json')).trim(),
  sessionSecret: (process.env.SESSION_SECRET || 'replace-me-in-production').trim(),
  magicLinkTTLMinutes: Number(process.env.MAGIC_LINK_TTL_MINUTES || 20),
  adminEmails: parseList(process.env.ADMIN_EMAILS),
  smtpHost: (process.env.SMTP_HOST || '').trim(),
  smtpPort: Number(process.env.SMTP_PORT || 587),
  smtpSecure: String(process.env.SMTP_SECURE || 'false').toLowerCase() === 'true',
  smtpUser: (process.env.SMTP_USER || '').trim(),
  smtpPass: (process.env.SMTP_PASS || '').trim(),
  smtpFrom: (process.env.SMTP_FROM || 'no-reply@glitcho.local').trim(),
  stripeSecretKey: (process.env.STRIPE_SECRET_KEY || '').trim(),
  stripeWebhookSecret: (process.env.STRIPE_WEBHOOK_SECRET || '').trim(),
  stripePriceId: (process.env.STRIPE_PRICE_ID || '').trim(),
  allowManualCheckout: String(
    process.env.ALLOW_MANUAL_CHECKOUT || (process.env.NODE_ENV === 'production' ? 'false' : 'true')
  ).toLowerCase() === 'true',
  licensePrivateKeyPEM: (process.env.LICENSE_PRIVATE_KEY_PEM || '').trim(),
  licensePrivateKeyPEMFile: (process.env.LICENSE_PRIVATE_KEY_PEM_FILE || '').trim(),
  offlineGraceHours: Number(process.env.LICENSE_OFFLINE_GRACE_HOURS || 48),
  licenseValidateRatePerMinute: Number(process.env.LICENSE_VALIDATE_RATE_PER_MINUTE || 120),
  authRequestRatePerMinute: Number(process.env.AUTH_REQUEST_RATE_PER_MINUTE || 15)
};

export function absoluteURL(pathname = '/') {
  const safePath = pathname.startsWith('/') ? pathname : `/${pathname}`;
  if (appConfig.publicBaseURL) {
    return `${appConfig.publicBaseURL.replace(/\/$/, '')}${safePath}`;
  }
  return `http://127.0.0.1:${appConfig.port}${safePath}`;
}

export function isAdminEmail(email) {
  const normalized = String(email || '').trim().toLowerCase();
  return Boolean(normalized) && appConfig.adminEmails.includes(normalized);
}

export function isStripeEnabled() {
  return Boolean(appConfig.stripeSecretKey) && Boolean(appConfig.stripePriceId);
}

export function readLicensePrivateKey() {
  if (appConfig.licensePrivateKeyPEM) {
    return appConfig.licensePrivateKeyPEM;
  }
  if (appConfig.licensePrivateKeyPEMFile) {
    try {
      return fs.readFileSync(appConfig.licensePrivateKeyPEMFile, 'utf8');
    } catch {
      return '';
    }
  }
  return '';
}
