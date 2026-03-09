import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import express from 'express';
import { appConfig, readLicensePrivateKey } from './lib/config.js';
import { createStore } from './lib/store.js';
import { createLogger, createInMemoryRateLimiter } from './lib/telemetry.js';
import { hashIP } from './lib/security.js';
import { canonicalPayload, signPayload } from './lib/license.js';
import { createGitHubLatestZipResolver } from './lib/github-releases.js';
import { marketingPage, downloadPage, notFoundPage, escapeHTML } from './lib/ui.js';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const logger = createLogger();
const store = await createStore(appConfig.storePath);
const privateKeyPEM = readLicensePrivateKey();
const donationURL = 'https://paypal.me/jcproulx';
const licenseValidateLimiter = createInMemoryRateLimiter(appConfig.licenseValidateRatePerMinute);
const resolveGitHubLatestZipURL = createGitHubLatestZipResolver({
  owner: appConfig.githubRepoOwner,
  repo: appConfig.githubRepoName,
  token: appConfig.githubToken,
  apiBaseURL: appConfig.githubReleaseAPIBaseURL,
  assetNamePattern: appConfig.githubReleaseAssetPattern,
  ttlMs: appConfig.githubReleaseCacheTTLSeconds * 1_000
});

const app = express();
app.disable('x-powered-by');
app.use(express.urlencoded({ extended: false }));
app.use(express.static(path.resolve(__dirname, '../public'), { maxAge: '5m' }));

function telemetry(event, metadata) {
  logger.info(event, metadata);
}

function requestNotice(req) {
  return String(req.query.notice || '').slice(0, 500);
}

function wantsJSON(req) {
  const accept = String(req.get('accept') || '');
  const contentType = String(req.get('content-type') || '');
  return req.path.startsWith('/api/') || accept.includes('application/json') || contentType.includes('application/json');
}

function retiredRouteHandler(req, res) {
  const message = 'This section has been removed. The website now only supports app download and donation.';
  if (wantsJSON(req)) {
    return res.status(410).json({ error: 'endpoint_removed', message });
  }
  return res.redirect('/?notice=This+section+has+been+removed');
}

async function resolvePublicDownloadURL() {
  try {
    const githubURL = await resolveGitHubLatestZipURL();
    if (githubURL) {
      return githubURL;
    }
  } catch (error) {
    logger.warn('download.github_latest_unavailable', {
      message: error.message,
      owner: appConfig.githubRepoOwner,
      repo: appConfig.githubRepoName
    });
  }

  if (appConfig.downloadURL) {
    return appConfig.downloadURL;
  }

  return '';
}

app.get('/health', (_req, res) => {
  res.set('cache-control', 'no-store');
  res.json({
    ok: true,
    service: 'glitcho-website',
    mode: 'promo-download-donate',
    signed: Boolean(privateKeyPEM)
  });
});

app.get('/', async (req, res) => {
  const resolvedDownloadURL = await resolvePublicDownloadURL();
  res.send(
    marketingPage({
      appName: appConfig.appName,
      notice: requestNotice(req),
      downloadURL: resolvedDownloadURL,
      donationURL
    })
  );
});

app.get('/download', async (req, res) => {
  const resolvedDownloadURL = await resolvePublicDownloadURL();
  res.send(
    downloadPage({
      appName: appConfig.appName,
      notice: requestNotice(req),
      downloadURL: resolvedDownloadURL,
      donationURL
    })
  );
});

app.get('/download/latest', async (req, res) => {
  const resolvedDownloadURL = await resolvePublicDownloadURL();
  if (resolvedDownloadURL) {
    return res.redirect(resolvedDownloadURL);
  }

  if (!fs.existsSync(appConfig.downloadFilePath)) {
    return res
      .status(404)
      .send(
        downloadPage({
          appName: appConfig.appName,
          notice: 'No download artifact is available yet. Publish a GitHub release zip or set DOWNLOAD_URL / DOWNLOAD_FILE_PATH.',
          downloadURL: resolvedDownloadURL,
          donationURL
        })
      );
  }

  return res.download(appConfig.downloadFilePath, 'Glitcho.zip');
});

app.use('/api/auth', retiredRouteHandler);
app.use('/api/me', retiredRouteHandler);
app.use('/api/admin', retiredRouteHandler);
app.use('/api/webhooks/stripe', retiredRouteHandler);
app.all('/auth/*', retiredRouteHandler);
app.all(['/pricing', '/login', '/account', '/admin', '/checkout', '/checkout/success', '/logout'], retiredRouteHandler);

app.post('/license/validate', express.json(), async (req, res) => {
  const rate = licenseValidateLimiter(req.ip || 'unknown');
  if (!rate.allowed) {
    return res.status(429).json({
      valid: false,
      expires_at: null,
      entitlements: [],
      signature: signPayload(canonicalPayload({ valid: false, expires_at: null, entitlements: [] }), privateKeyPEM),
      error: 'rate_limited',
      retry_after: rate.retryAfterSeconds
    });
  }

  const key = String(req.body?.key || '').trim();
  const deviceID = String(req.body?.device_id || '').trim();
  const appVersion = String(req.body?.app_version || '').trim();

  const license = store.findLicenseByKey(key);

  let valid = false;
  let expiresAt = null;
  let entitlements = [];

  if (license && !license.revoked) {
    expiresAt = license.expiresAt || null;
    const expiresAtMs = expiresAt ? Date.parse(expiresAt) : Number.NaN;
    const expired = Number.isFinite(expiresAtMs) && expiresAtMs < Date.now();
    if (!expired) {
      valid = true;
      entitlements = Array.isArray(license.entitlements) ? license.entitlements : [];
    }
  }

  const responsePayload = {
    valid,
    expires_at: expiresAt,
    entitlements
  };

  const signature = signPayload(canonicalPayload(responsePayload), privateKeyPEM);

  if (valid) {
    await store.recordActivation({
      licenseID: license.id,
      deviceID: deviceID || null,
      appVersion: appVersion || null,
      ipHash: hashIP(req.ip || 'unknown')
    });

    telemetry('license.validated', {
      licenseID: license.id,
      keyPrefix: key.slice(0, 10),
      deviceID: deviceID || 'unknown',
      appVersion: appVersion || 'unknown'
    });
  } else {
    telemetry('license.validation_failed', {
      keyPrefix: key.slice(0, 10),
      deviceID: deviceID || 'unknown'
    });
  }

  res.set('cache-control', 'no-store');
  return res.json({
    ...responsePayload,
    signature
  });
});

app.use((req, res) => {
  res.status(404).send(
    notFoundPage({
      appName: appConfig.appName,
      donationURL
    })
  );
});

app.use((error, req, res, _next) => {
  logger.error('server.unhandled_error', {
    path: req.path,
    method: req.method,
    message: error.message
  });

  if (wantsJSON(req)) {
    res.status(500).json({ error: 'internal_server_error' });
    return;
  }

  res.status(500).send(
    `<html><body style="font-family: sans-serif; background:#0b0e16; color:white; padding:40px;"><h1>Server Error</h1><p>${escapeHTML(
      error.message
    )}</p></body></html>`
  );
});

app.listen(appConfig.port, () => {
  logger.info('server.started', {
    port: appConfig.port,
    mode: 'promo-download-donate',
    downloadURL: appConfig.downloadURL || '/download/latest',
    storePath: appConfig.storePath
  });
});
