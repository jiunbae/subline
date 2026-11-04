/* Runs in YouTube's MAIN world. Never posts request URLs, tokens or cookies. */
(() => {
  'use strict';
  if (window.__nowPlayingBridge) return;
  window.__nowPlayingBridge = true;
  const CHANNEL = 'nowplaying-v1';
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
        isAd: !!p?.classList?.contains('ad-showing')
      }});
    } catch { /* DOM-only adapter remains available. */ }
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
      if (cues.length) post('captions', {videoId: id, cues, lang: url.searchParams.get('lang') || '', trackKind: asr ? 'asr' : 'manual'});
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
      if (!response.ok || Number(response.headers.get('content-length')) > 3_000_000) return;
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
    if (m.kind === 'connectCaptions') void connectCaptions();
  });
})();
