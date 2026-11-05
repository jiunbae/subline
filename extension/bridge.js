/* Runs in YouTube's MAIN world. Never posts request URLs, tokens or cookies. */
(() => {
  'use strict';
  if (window.__nowPlayingBridge) return;
  window.__nowPlayingBridge = true;
  const CHANNEL = 'nowplaying-v1';
  // Opt-in diagnostics: localStorage['nowplaying-debug'] = '1' in the YouTube tab (no data leaves the page).
  const debug = (() => { try { return localStorage.getItem('nowplaying-debug') === '1'; } catch { return false; } })();
  const log = (...args) => { if (debug) console.debug('[nowplaying]', ...args); };
  const describe = t => t?.languageCode ? t.languageCode + (t.kind === 'asr' ? ':asr' : '') +
    (t.translationLanguage?.languageCode ? '→' + t.translationLanguage.languageCode : '') + (t.vss_id ? '[listed]' : '') : String(t);
  const originalFetch = window.fetch;
  let lyricsBrowse = null, lyricsVideo = '', ccBusy = false;
  const videoId = () => new URL(location.href).searchParams.get('v') ||
    document.querySelector('#movie_player')?.getVideoData?.()?.video_id || '';
  const post = (kind, payload) => window.postMessage({channel: CHANNEL, direction: 'from-main', kind, ...payload}, location.origin);
  const player = () => document.querySelector('#movie_player') || document.querySelector('ytmusic-player')?.player_;
  function metadata() {
    try {
      const p = player();
      const response = p?.getPlayerResponse?.() || window.ytInitialPlayerResponse;
      const data = p?.getVideoData?.() || {};
      const details = response?.videoDetails;
      const id = videoId();
      // Initial response can belong to the previous SPA page.
      const valid = details?.videoId === id ? details : null;
      post('metadata', {videoId: id, data: {
        title: valid?.title || (data.video_id === id ? data.title : '') || '',
        artist: valid?.author || (data.video_id === id ? data.author : '') || '',
        duration: Number(valid?.lengthSeconds) || 0,
        thumbnails: valid?.thumbnail?.thumbnails || [],
        captionTracks: valid ? captionTracks(response) : [],
        translationLanguages: valid ? translationLanguages(response) : [],
        isAd: !!p?.classList?.contains('ad-showing')
      }});
    } catch { /* DOM-only adapter remains available. */ }
  }
  // Caption tracks the player offers: id is lang plus ":asr" for auto-generated ones.
  function captionTracks(response) {
    const list = response?.captions?.playerCaptionsTracklistRenderer?.captionTracks;
    if (!Array.isArray(list)) return [];
    return list.slice(0, 100).map(t => ({
      id: (t.languageCode || '') + (t.kind === 'asr' ? ':asr' : ''),
      lang: t.languageCode || '',
      name: String(t.name?.simpleText || (t.name?.runs || []).map(r => r.text).join('') || t.languageCode || '').slice(0, 80),
      ...(t.kind === 'asr' ? {kind: 'asr'} : {})
    })).filter((t, i, all) => /^[A-Za-z0-9_-]{1,24}(:asr)?$/.test(t.id) && all.findIndex(o => o.id === t.id) === i);
  }
  // Languages the player can auto-translate captions into; selectable as track id "x-<lang>".
  function translationLanguages(response) {
    const list = response?.captions?.playerCaptionsTracklistRenderer?.translationLanguages;
    if (!Array.isArray(list)) return [];
    return list.slice(0, 200).map(t => ({
      id: 'x-' + (t.languageCode || ''), lang: t.languageCode || '',
      name: String(t.languageName?.simpleText || (t.languageName?.runs || []).map(r => r.text).join('') || t.languageCode || '').slice(0, 80),
      kind: 'translation'
    })).filter(t => /^[A-Za-z0-9_-]{1,24}$/.test(t.id));
  }
  const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
  // The player does not refetch a track it already loaded, so keep the last few captured tracks.
  const captured = new Map(); // `${videoId}|${trackId}` → {cues, lang, trackKind}
  // Track ids the server refused for a video (e.g. 429 rate limiting on translations): stop waiting.
  const refused = new Set();
  function noteRefused(url, status, id) {
    if (url.pathname !== '/api/timedtext') return;
    const tlang = url.searchParams.get('tlang'), lang = url.searchParams.get('lang') || '';
    const trackId = tlang ? 'x-' + tlang : lang + (url.searchParams.get('kind') === 'asr' ? ':asr' : '');
    refused.add(`${id}|${trackId}`);
    log('refused', trackId, status);
  }
  function remember(id, trackId, value) {
    const key = `${id}|${trackId}`;
    captured.delete(key); captured.set(key, value);
    while (captured.size > 8) captured.delete(captured.keys().next().value);
  }
  // Makes the player itself fetch another caption track (so its PoToken applies), lets the timedtext
  // hook capture it, then restores the player's own caption state.
  // Caption operations run one at a time (main + secondary arrive back to back).
  let captionQueue = Promise.resolve();
  const queued = fn => (...args) => { captionQueue = captionQueue.then(() => fn(...args)).catch(() => {}); return captionQueue; };
  async function selectCaptionsNow(trackId) {
    const p = document.querySelector('#movie_player');
    const button = document.querySelector('.ytp-subtitles-button');
    if (ccBusy || !p?.setOption || !button || button.disabled) { log('select skipped', trackId, {ccBusy, player: !!p?.setOption, button: !!button}); return; }
    const id = videoId();
    log('select', trackId);
    const hit = captured.get(`${id}|${trackId}`);
    if (hit) { post('captions', {videoId: id, ...hit}); return; }
    ccBusy = true;
    refused.delete(`${id}|${trackId}`); // a refusal from an earlier attempt doesn't count for this one
    const wasOn = button.getAttribute('aria-pressed') === 'true';
    const current = () => { try { return p.getOption('captions', 'track'); } catch { return null; } };
    // The player's caption state in the plain form setOption accepts, including an active translation
    // (restored afterwards, so a user's own auto-translate stays on).
    const simple = t => t?.languageCode ? {languageCode: t.languageCode, ...(t.kind === 'asr' ? {kind: 'asr'} : {}),
      ...(t.translationLanguage?.languageCode ? {translationLanguage: {languageCode: t.translationLanguage.languageCode}} : {})} : null;
    const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);
    try {
      if (!wasOn) {
        button.click();
        // Wait for the captions module to settle on its default track.
        for (let i = 0; i < 10 && !current()?.languageCode; i++) await sleep(100);
      }
      if (videoId() !== id) return;
      // Restored afterwards: setOption also changes the player's remembered caption language.
      const original = simple(current());
      const translateTo = trackId.startsWith('x-') ? trackId.slice(2) : '';
      const [lang, asr] = [trackId.replace(/:asr$/, ''), trackId.endsWith(':asr')];
      let want, isWanted;
      if (translateTo) {
        // Auto-translate the player's current track (or its first manual one) into `translateTo`.
        let list = [];
        try { list = p.getOption('captions', 'tracklist') || []; } catch {}
        const base = simple(current()) || simple(list.find(t => t?.kind !== 'asr')) || simple(list[0]);
        if (!base) return;
        want = {languageCode: base.languageCode, ...(base.kind ? {kind: base.kind} : {}), translationLanguage: {languageCode: translateTo}};
        isWanted = () => current()?.translationLanguage?.languageCode === translateTo;
      } else {
        want = {languageCode: lang, ...(asr ? {kind: 'asr'} : {})};
        isWanted = () => current()?.languageCode === lang && (current()?.kind === 'asr') === asr && !current()?.translationLanguage;
      }
      // The track list may still be loading right after navigation.
      // The player honors the plain {languageCode, kind} form in most states, but while a translation is
      // active it ignores it and only accepts the track object from its own track list. Alternate.
      // Changing the translation target while one is active is ignored too: step back to the native
      // base track first (listed object), then apply the translation from there.
      const listed = (code, isAsr) => {
        let list = [];
        try { list = p.getOption('captions', 'tracklist') || []; } catch {}
        return list.find(t => t?.languageCode === code && (t.kind === 'asr') === isAsr) || null;
      };
      for (let i = 0; i < 12 && videoId() === id && !isWanted(); i++) {
        const translated = !!current()?.translationLanguage;
        let next = want;
        if (i % 2 === 1) {
          if (!translateTo) next = listed(lang, asr) || want;
          else if (translated) next = listed(want.languageCode, want.kind === 'asr') || want;
        }
        try { p.setOption('captions', 'track', next); } catch (e) { log('setOption threw', String(e)); }
        await sleep(250);
        log('  attempt', i, describe(next), '->', describe(current()));
      }
      if (videoId() !== id) return;
      log('wanted reached:', isWanted(), 'current', describe(current()), 'original', describe(original));
      if (isWanted()) {
        // Translations are generated server-side and can take several seconds; give them longer
        // before the player's own state is restored (which can cancel the request).
        for (let i = 0; i < (translateTo ? 20 : 10) && !captured.has(`${id}|${trackId}`) && !refused.has(`${id}|${trackId}`); i++) await sleep(200);
        log('captured in time:', captured.has(`${id}|${trackId}`));
        const got = captured.get(`${id}|${trackId}`);
        if (got) post('captions', {videoId: id, ...got}); // re-post in case it raced the app's choice
      }
      if (videoId() !== id || !button.isConnected) return;
      // Restore the player's own selection (with the same step-back out of an active translation).
      for (let i = 0; i < 4 && original && videoId() === id && !same(simple(current()), original); i++) {
        const next = i % 2 === 1 && current()?.translationLanguage
          ? (listed(original.languageCode, original.kind === 'asr') || original) : original;
        try { p.setOption('captions', 'track', next); } catch {}
        await sleep(150);
      }
      if (!wasOn && button.getAttribute('aria-pressed') === 'true') button.click();
    } finally { ccBusy = false; }
  }
  function discoverBrowse(value, id, depth = 0, budget = {n: 0}) {
    if (!value || typeof value !== 'object' || depth > 24 || ++budget.n > 25000) return;
    if (typeof value.browseId === 'string' && value.browseId.startsWith('MPLYt')) {
      lyricsBrowse = value.browseId; lyricsVideo = id; return;
    }
    for (const child of Object.values(value)) discoverBrowse(child, id, depth + 1, budget);
  }
  function parseXML(text, asr) {
    const xml = new DOMParser().parseFromString(text, 'text/xml');
    const rows = [...xml.querySelectorAll('text, p')].map(node => {
      const srv = node.tagName === 'p';
      const s = Number(node.getAttribute(srv ? 't' : 'start')) / (srv ? 1000 : 1);
      const duration = Number(node.getAttribute(srv ? 'd' : 'dur')) / (srv ? 1000 : 1);
      return {s, ...(duration > 0 ? {e: s + duration} : {}), text: node.textContent};
    });
    return NPParsers.normalizeCues(rows, asr);
  }
  function inspect(url, text, id) {
    if (typeof text !== 'string' || text.length > 3_000_000 || id !== videoId()) return;
    if (url.pathname === '/api/timedtext') {
      if (url.searchParams.get('v') && url.searchParams.get('v') !== id) return;
      const asr = url.searchParams.get('kind') === 'asr';
      const cues = text.trimStart().startsWith('{') ? NPParsers.parseJSON3(text, asr) : parseXML(text, asr);
      // Auto-translated responses carry the target language in tlang.
      const lang = url.searchParams.get('tlang') || url.searchParams.get('lang') || '';
      const translated = !!url.searchParams.get('tlang');
      const trackKind = asr && !translated ? 'asr' : 'manual';
      log('captured', url.searchParams.get('lang'), url.searchParams.get('tlang') || '', url.searchParams.get('kind') || '', cues.length);
      if (cues.length) {
        remember(id, translated ? 'x-' + lang : lang + (trackKind === 'asr' ? ':asr' : ''), {cues, lang, trackKind, translated});
        post('captions', {videoId: id, cues, lang, trackKind, translated});
      }
    }
  }
  function interesting(value) {
    try {
      const url = new URL(value, location.href);
      if (url.origin !== location.origin) return null;
      // Only the player's own caption fetch is observed. YTM next/browse responses are not inspected:
      // the page prefetches them for upcoming queue items, so they cannot be attributed to the current track.
      return url.pathname === '/api/timedtext' ? url : null;
    } catch { return null; }
  }
  window.fetch = function(input, init) {
    const url = interesting(typeof input === 'string' || input instanceof URL ? input : input?.url);
    const id = videoId();
    const result = originalFetch.call(this, input, init);
    if (url) result.then(response => {
      if (!response.ok) { noteRefused(url, response.status, id); return; }
      if (Number(response.headers.get('content-length')) > 3_000_000) return;
      response.clone().text().then(text => inspect(url, text, id)).catch(() => {});
    }).catch(() => {});
    return result;
  };
  const originalOpen = XMLHttpRequest.prototype.open;
  const xhrInfo = new WeakMap();
  XMLHttpRequest.prototype.open = function(method, url, ...rest) {
    xhrInfo.set(this, {url: interesting(url), id: videoId()});
    return originalOpen.call(this, method, url, ...rest);
  };
  const originalSend = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.send = function(...args) {
    const info = xhrInfo.get(this);
    if (info?.url) this.addEventListener('load', () => {
      try {
        if (this.status >= 400) noteRefused(info.url, this.status, info.id);
        if (this.status >= 200 && this.status < 300) inspect(info.url,
          this.responseType === 'json' ? JSON.stringify(this.response) : this.responseText, info.id);
      } catch { /* Binary/blocked response. */ }
    }, {once: true});
    return originalSend.apply(this, args);
  };
  // Same auth the YTM web client attaches to its own youtubei calls; computed and used only in-page.
  async function authHeaders() {
    const sapisid = document.cookie.split('; ').map(c => c.split('=')).find(([k]) => k === 'SAPISID' || k === '__Secure-3PAPISID')?.[1];
    if (!sapisid) return {};
    const ts = Math.floor(Date.now() / 1000);
    const digest = await crypto.subtle.digest('SHA-1', new TextEncoder().encode(`${ts} ${sapisid} ${location.origin}`));
    const hex = [...new Uint8Array(digest)].map(b => b.toString(16).padStart(2, '0')).join('');
    return {'Authorization': `SAPISIDHASH ${ts}_${hex}`, 'X-Goog-AuthUser': String(window.ytcfg?.get?.('SESSION_INDEX') ?? 0), 'X-Origin': location.origin};
  }
  function plainLyrics(json) {
    let text = '';
    (function walk(v, d) {
      if (text || !v || typeof v !== 'object' || d > 20) return;
      const runs = v.musicDescriptionShelfRenderer?.description?.runs;
      if (Array.isArray(runs)) { text = runs.map(r => r?.text || '').join(''); return; }
      for (const c of Object.values(v)) walk(c, d + 1);
    })(json, 0);
    return text.split('\n').map(l => l.trim()).filter(Boolean).slice(0, 2000).map((line, i) => ({s: i, text: line}));
  }
  async function getLyrics(id) {
    if (location.hostname !== 'music.youtube.com' || id !== videoId()) return;
    try {
      const base = window.ytcfg?.get?.('INNERTUBE_CONTEXT');
      if (!base) throw new Error('No context');
      const request = async (endpoint, body) => {
        const response = await originalFetch.call(window, `/youtubei/v1/${endpoint}?prettyPrint=false`, {
          method: 'POST', credentials: 'same-origin', signal: AbortSignal.timeout(7000),
          headers: {'Content-Type': 'application/json', ...await authHeaders()},
          body: JSON.stringify({context: structuredClone(base), ...body})
        });
        if (!response.ok) throw new Error('Unavailable');
        return response.json();
      };
      if (lyricsVideo !== id || !lyricsBrowse) {
        lyricsBrowse = null;
        const next = await request('next', {videoId: id});
        if (id !== videoId()) return;
        discoverBrowse(next, id);
      }
      if (lyricsVideo !== id || !lyricsBrowse) throw new Error('No lyrics');
      const json = await request('browse', {browseId: lyricsBrowse});
      if (id !== videoId()) return;
      const timed = NPParsers.parseTimedLyrics(json);
      if (timed.length) post('lyrics', {videoId: id, cues: timed, synced: true});
      else post('lyrics', {videoId: id, cues: plainLyrics(json), synced: false});
    } catch { if (id === videoId()) post('lyrics', {videoId: id, cues: []}); }
  }
  async function connectCaptions() {
    if (ccBusy) return;
    const button = document.querySelector('.ytp-subtitles-button');
    if (!button || button.disabled || button.getAttribute('aria-disabled') === 'true') return;
    ccBusy = true;
    const id = videoId(), original = button.getAttribute('aria-pressed');
    try {
      // Only an explicit connect request may briefly change the CC state.
      if (original === 'false') {
        button.click();
        await new Promise(resolve => setTimeout(resolve, 1200));
        if (videoId() === id && button.isConnected && button.getAttribute('aria-pressed') === 'true') button.click();
      } else if (original === 'true') {
        button.click();
        await new Promise(resolve => setTimeout(resolve, 80));
        if (videoId() === id && button.isConnected && button.getAttribute('aria-pressed') === 'false') button.click();
      }
    } finally { ccBusy = false; }
  }
  window.addEventListener('message', event => {
    const m = event.data;
    if (event.source !== window || event.origin !== location.origin || m?.channel !== CHANNEL || m.direction !== 'to-main') return;
    if (m.kind === 'metadata') metadata();
    if (m.kind === 'lyrics' && typeof m.videoId === 'string') void getLyrics(m.videoId);
    // Commands name the video they were issued for; queued work for a video we already left is dropped
    // before it touches the player (SPA navigation can happen while an earlier command runs).
    const forCurrent = fn => (...args) => (typeof m.videoId !== 'string' || m.videoId === videoId()) ? fn(...args) : undefined;
    if (m.kind === 'connectCaptions') void queued(forCurrent(connectCaptions))();
    if (m.kind === 'selectCaptions' && typeof m.trackId === 'string' && /^[A-Za-z0-9_-]{1,24}(:asr)?$/.test(m.trackId)) void queued(forCurrent(selectCaptionsNow))(m.trackId);
  });
})();
