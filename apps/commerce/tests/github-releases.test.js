import test from 'node:test';
import assert from 'node:assert/strict';
import { createGitHubLatestZipResolver, pickLatestReleaseZipURL } from '../src/lib/github-releases.js';

test('pickLatestReleaseZipURL prefers .zip asset download url', () => {
  const url = pickLatestReleaseZipURL({
    zipball_url: 'https://api.github.com/repos/owner/repo/zipball/v1.2.3',
    assets: [
      { name: 'Glitcho.dmg', browser_download_url: 'https://example.com/Glitcho.dmg' },
      { name: 'Glitcho-macOS.zip', browser_download_url: 'https://example.com/Glitcho-macOS.zip' }
    ]
  });

  assert.equal(url, 'https://example.com/Glitcho-macOS.zip');
});

test('pickLatestReleaseZipURL falls back to zipball_url', () => {
  const url = pickLatestReleaseZipURL({
    zipball_url: 'https://api.github.com/repos/owner/repo/zipball/v1.2.3',
    assets: [{ name: 'Glitcho.dmg', browser_download_url: 'https://example.com/Glitcho.dmg' }]
  });

  assert.equal(url, 'https://api.github.com/repos/owner/repo/zipball/v1.2.3');
});

test('createGitHubLatestZipResolver caches resolved URL within TTL', async () => {
  let calls = 0;
  let clock = 1_000;
  const resolver = createGitHubLatestZipResolver({
    owner: 'Jencryzthers',
    repo: 'glitcho',
    ttlMs: 5_000,
    now: () => clock,
    fetchImpl: async () => {
      calls += 1;
      return {
        ok: true,
        json: async () => ({
          assets: [{ name: 'Glitcho.zip', browser_download_url: 'https://example.com/Glitcho.zip' }]
        })
      };
    }
  });

  const first = await resolver();
  const second = await resolver();

  clock += 6_000;
  const third = await resolver();

  assert.equal(first, 'https://example.com/Glitcho.zip');
  assert.equal(second, 'https://example.com/Glitcho.zip');
  assert.equal(third, 'https://example.com/Glitcho.zip');
  assert.equal(calls, 2);
});
