import test from 'node:test';
import assert from 'node:assert/strict';
import { marketingPage, downloadPage } from '../src/lib/ui.js';

test('marketing page renders brand icon and promo screenshots', () => {
  const html = marketingPage({
    appName: 'Glitcho',
    notice: '',
    downloadURL: '/download/latest',
    donationURL: 'https://paypal.me/jcproulx'
  });

  assert.match(html, /\/images\/brand\/app-icon\.png/);
  assert.match(html, /\/images\/promos\/promo-1-1280\.jpg/);
  assert.match(html, /\/images\/promos\/promo-2-1280\.jpg/);
  assert.match(html, /\/images\/promos\/promo-3-1280\.jpg/);
  assert.match(html, /\/images\/promos\/promo-4-1280\.jpg/);
  assert.match(html, /srcset=\"[^\"]+800w,[^\"]+1280w\"/);
  assert.match(html, /id=\"preview-modal\"/);
  assert.match(html, /src=\"\/preview-modal\.js\"/);
  assert.match(html, /data-preview-full=\"\/images\/promos\/promo-1-1280\.jpg\"/);
  assert.doesNotMatch(html, /class=\"preview-tile\" href=/);
  assert.doesNotMatch(html, /https:\/\/paypal\.me\/jcproulx/);
  assert.doesNotMatch(html, /Pro feature unlock with signed validation/i);
  assert.doesNotMatch(html, /licensing/i);
  assert.doesNotMatch(html, /Native stream player/i);
  assert.match(html, /id=\"boot-splash\"/);
  assert.match(html, /src=\"\/splash\.js\"/);
  assert.doesNotMatch(html, /href=\"\/pricing\"/);
  assert.doesNotMatch(html, /href=\"\/login\"/);
  assert.doesNotMatch(html, /href=\"\/account\"/);
  assert.doesNotMatch(html, /\$/);
});

test('download page includes runtime/dependency instructions and github reference', () => {
  const html = downloadPage({
    appName: 'Glitcho',
    notice: '',
    downloadURL: '/download/latest',
    donationURL: 'https://paypal.me/jcproulx'
  });

  assert.match(html, /Runtime notes/i);
  assert.match(html, /brew install streamlink/i);
  assert.match(html, /brew install ffmpeg/i);
  assert.match(html, /Install Streamlink/i);
  assert.match(html, /https:\/\/github\.com\/Jencryzthers\/glitcho/i);
  assert.doesNotMatch(html, /1\.\s*Download/i);
  const depsSection = html.match(/<section class=\"card deps-card\">[\s\S]*?<\/section>/i)?.[0] || '';
  assert.doesNotMatch(depsSection, /Glitcho is unofficial and not affiliated/i);
  assert.match(html, /<footer class=\"site-footer\">[\s\S]*Glitcho is unofficial and not affiliated with Twitch Interactive, Inc\. or Amazon\.com, Inc\./i);
  assert.doesNotMatch(html, /Need to support development/i);
  assert.doesNotMatch(html, /paypal\.me\/jcproulx/i);
});
