function escapeHTML(value) {
  return String(value || '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

function layout({ title, appName, notice, content, donationURL, showFooterDonation = true }) {
  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>${escapeHTML(title)} · ${escapeHTML(appName)}</title>
  <link rel="stylesheet" href="/styles.css" />
</head>
<body>
  <div id="boot-splash" class="boot-splash" aria-hidden="true">
    <div class="boot-splash-glow"></div>
    <div class="boot-splash-content">
      <div class="boot-splash-ring">
        <img src="/images/brand/app-icon.png" alt="${escapeHTML(appName)} icon" width="82" height="82" />
      </div>
      <h1 class="boot-splash-title">${escapeHTML(appName)}</h1>
      <div class="boot-splash-dots">
        <span></span>
        <span></span>
        <span></span>
      </div>
    </div>
  </div>
  <div class="bg-orb orb-1"></div>
  <div class="bg-orb orb-2"></div>
  <header class="topbar-wrap">
    <div class="topbar">
      <a class="brand" href="/">
        <img class="brand-icon" src="/images/brand/app-icon.png" alt="${escapeHTML(appName)} app icon" width="36" height="36" />
        <span class="brand-text">${escapeHTML(appName)}</span>
      </a>
      <nav class="top-nav">
        <a class="nav-link" href="/">Home</a>
        <a class="nav-link" href="/download">Download</a>
      </nav>
    </div>
  </header>
  <main class="page-shell">
    ${notice ? `<div class="notice">${escapeHTML(notice)}</div>` : ''}
    ${content}
  </main>
  <footer class="site-footer">
    <div class="site-footer-copy">
      <p>${escapeHTML(appName)} for macOS</p>
      <p class="footer-legal">Glitcho is unofficial and not affiliated with Twitch Interactive, Inc. or Amazon.com, Inc.</p>
    </div>
    ${showFooterDonation ? `<a class="footer-link" href="${escapeHTML(donationURL)}" target="_blank" rel="noopener noreferrer">Optional donation</a>` : ''}
  </footer>
  <div id="preview-modal" class="preview-modal" aria-hidden="true" role="dialog" aria-modal="true">
    <button type="button" class="preview-modal-backdrop" data-preview-close aria-label="Close image preview"></button>
    <div class="preview-modal-content">
      <button type="button" class="preview-modal-close" data-preview-close aria-label="Close image preview">Close</button>
      <img id="preview-modal-image" src="" alt="" />
    </div>
  </div>
  <script src="/splash.js" defer></script>
  <script src="/preview-modal.js" defer></script>
</body>
</html>`;
}

export function marketingPage({ appName, notice, downloadURL, donationURL }) {
  return layout({
    title: appName,
    appName,
    notice,
    donationURL,
    showFooterDonation: false,
    content: `
      <section class="hero card">
        <div class="hero-copy">
          <p class="eyebrow">Native Twitch Experience</p>
          <h1>A polished Twitch desktop app that feels truly native on macOS.</h1>
          <p class="muted">Glitcho combines a smooth player, rich streamer pages, and recording workflows in a clean native interface with no browser clutter.</p>
          <div class="actions hero-actions">
            <a class="btn btn-primary btn-large" href="${escapeHTML(downloadURL || '/download/latest')}">Download .zip</a>
          </div>
          <div class="hero-chips">
            <span class="chip">Native Player</span>
            <span class="chip">Streamer Pages</span>
            <span class="chip">Recording Tools</span>
          </div>
        </div>
        <div class="hero-showcase">
          <figure class="hero-shot hero-shot-main">
            <img
              src="/images/promos/promo-1-800.jpg"
              srcset="/images/promos/promo-1-800.jpg 800w, /images/promos/promo-1-1280.jpg 1280w"
              sizes="(max-width: 980px) 100vw, 44vw"
              width="1280"
              height="720"
              alt="Glitcho native player and stream view"
              loading="eager"
              decoding="async"
            />
          </figure>
          <figure class="hero-shot hero-shot-secondary">
            <img
              src="/images/promos/promo-2-800.jpg"
              srcset="/images/promos/promo-2-800.jpg 800w, /images/promos/promo-2-1280.jpg 1280w"
              sizes="(max-width: 980px) 100vw, 24vw"
              width="1280"
              height="720"
              alt="Glitcho channel details and tabs"
              loading="lazy"
              decoding="async"
            />
          </figure>
        </div>
      </section>

      <section class="details-grid">
        <article class="card detail-card">
          <p class="eyebrow">Playback</p>
          <h2>Built on native AVKit with Streamlink input</h2>
          <p class="muted">Glitcho uses a native playback pipeline (Streamlink to AVPlayer) with in-player overlay controls and shared behavior across live streams and local recordings.</p>
          <ul class="detail-list">
            <li>Native fullscreen, Picture in Picture, and chat collapse/popout controls.</li>
            <li>Zoom and pan support with consistent controls for both live and recorded content.</li>
            <li>Focused UI that removes Twitch web clutter while preserving channel context.</li>
          </ul>
        </article>
        <article class="card detail-card">
          <p class="eyebrow">Streamer Pages</p>
          <h2>About, Videos, and Schedule rendered in native UI</h2>
          <p class="muted">Streamer details are converted into native components with a collapsible panel under the player, so navigation stays fast and consistent.</p>
          <ul class="detail-list">
            <li>About tab scraper converts linked images into tappable native cards.</li>
            <li>Videos and clips routes handle online/offline channel states correctly.</li>
            <li>Schedule tab is integrated beside About and Videos with native rendering.</li>
          </ul>
        </article>
      </section>

      <section class="details-grid">
        <article class="card detail-card">
          <p class="eyebrow">Recording</p>
          <h2>DVR-style tools and background controls</h2>
          <p class="muted">Recording includes confirmation flows, background agent controls, and scoped auto-record modes designed to avoid runaway process spawning.</p>
          <ul class="detail-list">
            <li>Auto-record scope by pinned, followed, pinned plus followed, or custom allowlist.</li>
            <li>Blocklist overrides, cooldown/debounce behavior, and concurrency controls.</li>
            <li>Bulk library actions, export progress, and retention rules (age + keep-last limits).</li>
          </ul>
        </article>
        <article class="card detail-card">
          <p class="eyebrow">Reliability</p>
          <h2>Background recorder agent with process guardrails</h2>
          <p class="muted">The recorder architecture is designed for deterministic restart/stop flows and improved lifecycle stability under long-running sessions.</p>
          <ul class="detail-list">
            <li>Background recorder LaunchAgent support with restart and kill controls.</li>
            <li>Status feedback and confirmation flows for high-impact actions.</li>
            <li>Profiling workflow to track CPU, RAM, and capture process peaks.</li>
          </ul>
        </article>
      </section>

      <section class="card preview-section">
        <div class="preview-head">
          <p class="eyebrow">Preview</p>
          <h2>Real Glitcho interface</h2>
          <p class="muted">Screenshots below are direct captures from the current macOS build.</p>
        </div>
        <div class="preview-strip" aria-label="Glitcho screenshot previews">
          <button class="preview-tile" type="button" data-preview-full="/images/promos/promo-1-1280.jpg" data-preview-alt="Glitcho native player and stream view">
            <img
              src="/images/promos/promo-1-800.jpg"
              srcset="/images/promos/promo-1-800.jpg 800w, /images/promos/promo-1-1280.jpg 1280w"
              sizes="(max-width: 980px) 70vw, 280px"
              width="1280"
              height="720"
              alt="Glitcho native player and stream view"
              loading="lazy"
              decoding="async"
            />
          </button>
          <button class="preview-tile" type="button" data-preview-full="/images/promos/promo-2-1280.jpg" data-preview-alt="Glitcho channel details and tabs">
            <img
              src="/images/promos/promo-2-800.jpg"
              srcset="/images/promos/promo-2-800.jpg 800w, /images/promos/promo-2-1280.jpg 1280w"
              sizes="(max-width: 980px) 70vw, 280px"
              width="1280"
              height="720"
              alt="Glitcho channel details and tabs"
              loading="lazy"
              decoding="async"
            />
          </button>
          <button class="preview-tile" type="button" data-preview-full="/images/promos/promo-3-1280.jpg" data-preview-alt="Glitcho settings and recording workflows">
            <img
              src="/images/promos/promo-3-800.jpg"
              srcset="/images/promos/promo-3-800.jpg 800w, /images/promos/promo-3-1280.jpg 1280w"
              sizes="(max-width: 980px) 70vw, 280px"
              width="1280"
              height="720"
              alt="Glitcho settings and recording workflows"
              loading="lazy"
              decoding="async"
            />
          </button>
          <button class="preview-tile" type="button" data-preview-full="/images/promos/promo-4-1280.jpg" data-preview-alt="Glitcho recordings and content management UI">
            <img
              src="/images/promos/promo-4-800.jpg"
              srcset="/images/promos/promo-4-800.jpg 800w, /images/promos/promo-4-1280.jpg 1280w"
              sizes="(max-width: 980px) 70vw, 280px"
              width="1280"
              height="720"
              alt="Glitcho recordings and content management UI"
              loading="lazy"
              decoding="async"
            />
          </button>
        </div>
      </section>

    `
  });
}

export function downloadPage({ appName, notice, downloadURL, donationURL }) {
  return layout({
    title: 'Download',
    appName,
    notice,
    donationURL,
    showFooterDonation: false,
    content: `
      <section class="card download-hero">
        <p class="eyebrow">Latest Build</p>
        <h1>Download Glitcho for macOS</h1>
        <p class="muted">Get the latest zip package and launch Glitcho with the native app workflow.</p>
        <div class="actions">
          <a class="btn btn-primary btn-large" href="${escapeHTML(downloadURL || '/download/latest')}">Download .zip</a>
          <a class="btn btn-soft btn-large" href="https://github.com/Jencryzthers/glitcho" target="_blank" rel="noopener noreferrer">View on GitHub</a>
        </div>
      </section>

      <section class="card requirements-card">
        <p class="eyebrow">Requirements</p>
        <h2>Runtime notes</h2>
        <div class="requirements-grid">
          <div>
            <h3>Platform</h3>
            <p class="muted">macOS 13 or newer. Glitcho is currently distributed as a macOS-native SwiftUI app.</p>
          </div>
          <div>
            <h3>Dependencies</h3>
            <p class="muted">Streamlink is required for native playback and recording. FFmpeg is optional for remux workflows.</p>
          </div>
          <div>
            <h3>Network</h3>
            <p class="muted">Requires Twitch connectivity to browse channels and play streams.</p>
          </div>
        </div>
      </section>

      <section class="card deps-card">
        <p class="eyebrow">Setup</p>
        <h2>Install dependencies for native playback and recording</h2>
        <p class="muted">Glitcho can auto-detect or install tools from Settings, but command-line install is the fastest path.</p>
        <div class="deps-grid">
          <div>
            <h3>1. Install Streamlink</h3>
            <pre class="code-block"><code>brew install streamlink</code></pre>
            <p class="muted">Required for the native player stream input pipeline.</p>
          </div>
          <div>
            <h3>2. Install FFmpeg (optional)</h3>
            <pre class="code-block"><code>brew install ffmpeg</code></pre>
            <p class="muted">Used for optional recording remux/processing workflows.</p>
          </div>
          <div>
            <h3>3. Verify tools</h3>
            <pre class="code-block"><code>streamlink --version\nffmpeg -version</code></pre>
            <p class="muted">Then open Glitcho Settings and use “Choose Streamlink/FFmpeg” if manual paths are needed.</p>
          </div>
        </div>
      </section>
    `
  });
}

export function notFoundPage({ appName, donationURL }) {
  return layout({
    title: 'Not found',
    appName,
    notice: '',
    donationURL,
    content: `
      <section class="card small-card">
        <h1>Not found</h1>
        <p class="muted">The requested page does not exist.</p>
        <div class="actions">
          <a class="btn" href="/">Go home</a>
          <a class="btn" href="/download">Download</a>
        </div>
      </section>
    `
  });
}

export { escapeHTML };
