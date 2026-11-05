// Real-YouTube E2E: launches Chromium with the unpacked extension, plays a video and prints the app's
// state every 2.5 s (requires `defaults write com.nowplaying.app debugDump -bool true`).
// usage: node youtube.mjs <watch URL> [seconds=30] [--cc-off]
//   CHROME=/path/to/Chromium   (default: Playwright's bundled Chromium)
//   PROFILE=dir                (default: build/e2e-profile; log in there once for YouTube Music)
// Caption preferences are taken from the app (captionTrack / captionTrack2 defaults).
import { chromium } from 'playwright-core';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const [url, secs = '30'] = process.argv.slice(2).filter(a => !a.startsWith('--'));
const ccOff = process.argv.includes('--cc-off');
if (!url) { console.error('usage: node youtube.mjs <url> [seconds] [--cc-off]'); process.exit(1); }
const UD = process.env.PROFILE || path.join(root, 'build/e2e-profile');
fs.mkdirSync(path.join(UD, 'NativeMessagingHosts'), { recursive: true });
fs.writeFileSync(path.join(UD, 'NativeMessagingHosts/com.nowplaying.host.json'), JSON.stringify({
  name: 'com.nowplaying.host', description: 'e2e', path: path.join(os.homedir(), 'Applications/NowPlaying.app/Contents/Helpers/np-host'),
  type: 'stdio', allowed_origins: ['chrome-extension://npkfiaebcfackgbinodgjobdlmeceaij/'] }));
const ext = path.join(root, 'extension');
const ctx = await chromium.launchPersistentContext(UD, {
  ...(process.env.CHROME ? { executablePath: process.env.CHROME } : {}), headless: false, viewport: { width: 1100, height: 700 },
  ignoreDefaultArgs: ['--disable-extensions', '--mute-audio', '--enable-automation'],
  args: [`--disable-extensions-except=${ext}`, `--load-extension=${ext}`, '--autoplay-policy=no-user-gesture-required',
         '--window-position=0,0', '--disable-blink-features=AutomationControlled'],
});
const killer = setTimeout(() => { ctx.close(); process.exit(2); }, (+secs + 90) * 1000); // never leave a browser behind
const page = ctx.pages()[0] || await ctx.newPage();
const go = async u => { for (let k = 0; k < 3; k++) { try { await page.goto(u, { waitUntil: 'domcontentloaded' }); return; } catch { await page.waitForTimeout(1500); } } };
const adShowing = () => page.evaluate(() => document.querySelector('#movie_player')?.classList.contains('ad-showing'));
await page.waitForTimeout(1000); await go(url); await page.waitForTimeout(3000);
if (ccOff) { // make the player's own CC preference "off", then start fresh
  for (let i = 0; i < 15 && await adShowing(); i++) await page.waitForTimeout(2000);
  if (await page.getAttribute('.ytp-subtitles-button', 'aria-pressed').catch(() => null) === 'true') {
    await page.hover('#movie_player'); await page.click('.ytp-subtitles-button'); await page.waitForTimeout(600);
  }
  await page.reload({ waitUntil: 'domcontentloaded' }); await page.waitForTimeout(2500);
}
await page.evaluate(() => { const v = document.querySelector('video'); if (v) { v.muted = true; v.play().catch(() => {}); } });
const dumpPath = path.join(os.homedir(), 'Library/Application Support/NowPlaying/debug-state.json');
const dump = () => { try { return JSON.parse(fs.readFileSync(dumpPath, 'utf8')); } catch { return {}; } };
for (let i = 0; i < Math.ceil(+secs / 2.5); i++) {
  await page.waitForTimeout(2500);
  const cc = await page.getAttribute('.ytp-subtitles-button', 'aria-pressed').catch(() => null);
  const d = dump();
  console.log(`t+${((i + 1) * 2.5).toFixed(1)}s cc=${cc}`, JSON.stringify({ ad: d.isAd, title: d.title?.slice(0, 30), src: d.cueSource, n: d.cueCount,
    cur: d.captionTrackID, sub: d.secondaryTrackID, n2: d.secondaryCount, st: d.textStatus, line: d.currentLine?.slice(0, 40), line2: d.secondaryLine?.slice(0, 40) }));
}
clearTimeout(killer); await ctx.close();
