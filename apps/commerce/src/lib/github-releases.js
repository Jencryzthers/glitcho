function sanitizeBaseURL(value, fallback) {
  const raw = String(value || '').trim();
  return (raw || fallback).replace(/\/$/, '');
}

export function pickLatestReleaseZipURL(release, options = {}) {
  const assetNamePattern = String(options.assetNamePattern || '').trim();
  const assets = Array.isArray(release?.assets) ? release.assets : [];

  if (assetNamePattern) {
    const matcher = new RegExp(assetNamePattern, 'i');
    const matched = assets.find(asset => {
      const name = String(asset?.name || '');
      const url = String(asset?.browser_download_url || '');
      return Boolean(url) && matcher.test(name);
    });
    if (matched?.browser_download_url) {
      return matched.browser_download_url;
    }
  }

  const zipAsset = assets.find(asset => {
    const name = String(asset?.name || '');
    const url = String(asset?.browser_download_url || '');
    return Boolean(url) && /\.zip$/i.test(name);
  });

  if (zipAsset?.browser_download_url) {
    return zipAsset.browser_download_url;
  }

  const zipball = String(release?.zipball_url || '').trim();
  if (zipball.startsWith('http://') || zipball.startsWith('https://')) {
    return zipball;
  }

  return '';
}

export function createGitHubLatestZipResolver({
  owner,
  repo,
  token = '',
  apiBaseURL = 'https://api.github.com',
  assetNamePattern = '',
  ttlMs = 300_000,
  fetchImpl = globalThis.fetch,
  now = () => Date.now()
}) {
  const normalizedOwner = String(owner || '').trim();
  const normalizedRepo = String(repo || '').trim();
  const normalizedBase = sanitizeBaseURL(apiBaseURL, 'https://api.github.com');
  const safeTTL = Math.max(0, Number(ttlMs) || 0);

  if (!normalizedOwner || !normalizedRepo) {
    throw new Error('github_repo_not_configured');
  }
  if (typeof fetchImpl !== 'function') {
    throw new Error('fetch_not_available');
  }

  let cacheURL = '';
  let cacheExpiry = 0;

  return async function resolveGitHubLatestZipURL() {
    const nowMs = Number(now()) || Date.now();
    if (cacheURL && nowMs < cacheExpiry) {
      return cacheURL;
    }

    const endpoint = `${normalizedBase}/repos/${encodeURIComponent(normalizedOwner)}/${encodeURIComponent(normalizedRepo)}/releases/latest`;
    const headers = {
      accept: 'application/vnd.github+json',
      'user-agent': 'glitcho-commerce-site'
    };
    if (token) {
      headers.authorization = `Bearer ${token}`;
    }

    const response = await fetchImpl(endpoint, { method: 'GET', headers });
    if (!response.ok) {
      throw new Error(`github_latest_release_http_${response.status}`);
    }

    const payload = await response.json();
    const resolvedURL = pickLatestReleaseZipURL(payload, { assetNamePattern });
    if (!resolvedURL) {
      throw new Error('github_latest_release_no_zip');
    }

    cacheURL = resolvedURL;
    cacheExpiry = nowMs + safeTTL;
    return resolvedURL;
  };
}
