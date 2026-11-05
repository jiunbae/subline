'use strict';
importScripts('parsers.js');
const HOST = 'com.nowplaying.host';
const MATCH = ['*://www.youtube.com/*', '*://music.youtube.com/*'];
const states = new Map(), sequences = new Map(), lyricCache = new Map(), inflight = new Map();
let port = null, retry = null, backoff = 1000, visible = true;
// A wall-clock epoch prevents sequence regression after an MV3 worker restart;
// increment separately per tab, and never reset at native reconnect/video change.
const epoch = Date.now() * 1000;
const RETRY_ALARM = 'nowplaying-native-reconnect';
function nextSeq(tabId) {
  const seq = (sequences.get(tabId) ?? epoch) + 1;
  sequences.set(tabId, seq); return seq;
}
function allowed(url) {
  try { const u = new URL(url); return ['http:','https:'].includes(u.protocol) && ['www.youtube.com','music.youtube.com'].includes(u.hostname); }
  catch { return false; }
}
function nativeSend(tabId, message) {
  if (!port) return;
  try { port.postMessage({...message, v:1, tabId, seq:nextSeq(tabId)}); }
  catch { disconnect(); }
}
function disconnect() {
  const old = port; port = null;
  try { old?.disconnect(); } catch {}
  if (!retry) {
    retry = setTimeout(() => { retry = null; connect(); }, backoff);
    // JS timers do not survive MV3 suspension; this alarm is a wake watchdog.
    void chrome.alarms.create(RETRY_ALARM, {delayInMinutes:0.5});
    backoff = Math.min(30000, backoff * 2);
  }
}
function toTab(tabId, message) {
  return chrome.tabs.sendMessage(tabId, message).catch(() => {});
}
async function snapshot() {
  const tabs = await chrome.tabs.query({url:MATCH});
  const ids = new Set(tabs.map(t => t.id));
  for (const [id, state] of states) {
    if (!ids.has(id)) { states.delete(id); continue; }
    for (const type of ['track','clock','cues','cues2','captionTracks']) if (state[type] && !(type.startsWith('cues') && state.track?.isAd)) nativeSend(id, state[type]);
  }
  await Promise.all(tabs.map(t => toTab(t.id, {type:'visibility', visible})));
  await Promise.all(tabs.map(t => toTab(t.id, {type:'requestSnapshot'})));
}
function connect() {
  if (port) return;
  try {
    const connection = chrome.runtime.connectNative(HOST);
    port = connection;
    void chrome.alarms.clear(RETRY_ALARM);
    connection.onDisconnect.addListener(() => {
      // Read lastError to consume Chrome's expected missing-host error.
      void chrome.runtime.lastError;
      if (port === connection) disconnect();
    });
    connection.onMessage.addListener(message => {
      if (port !== connection || message?.v !== 1) return;
      // Receiving anything demonstrates a usable round trip.
      backoff = 1000;
      if (message.type === 'requestSnapshot') void snapshot();
      else if (message.type === 'visibility' && typeof message.visible === 'boolean') {
        visible = message.visible;
        void chrome.tabs.query({url:MATCH}).then(tabs => Promise.all(tabs.map(t => toTab(t.id, {type:'visibility', visible}))));
      } else if (['cmd','connectCaptions','selectCaptions'].includes(message.type) && Number.isInteger(message.tabId)) {
        if (message.type === 'selectCaptions' && !(typeof message.trackId === 'string' &&
          (TRACK_ID.test(message.trackId) || (message.slot === 2 && message.trackId === '')))) return;
        if (message.type === 'cmd' && (!['play','pause','toggle','next','prev','seek'].includes(message.action) ||
          (message.action === 'seek' && !Number.isFinite(message.t)))) return;
        void chrome.tabs.get(message.tabId).then(tab => {
          if (allowed(tab.url)) return toTab(message.tabId, message);
        }).catch(() => {});
      }
    });
    nativeSend(-1, {type:'hello', ext:chrome.runtime.getManifest().version, ua:navigator.userAgent});
    void snapshot();
  } catch { disconnect(); }
}
const TRACK_ID = /^[A-Za-z0-9_-]{1,24}(:asr)?$/;
function sanitize(raw) {
  if (!raw || typeof raw !== 'object') return null;
  const str = (value, max = 2000) => typeof value === 'string' ? value.slice(0,max) : '';
  if (raw.type === 'gone') return {type:'gone'};
  const id = str(raw.videoId, 32);
  if (!/^[\w-]{11}$/.test(id)) return null;
  const common = {type:raw.type, videoId:id};
  if (raw.type === 'track') {
    if (!['yt','ytm'].includes(raw.site) || !Array.isArray(raw.artwork)) return null;
    return {...common, site:raw.site, title:str(raw.title), artist:str(raw.artist), album:str(raw.album),
      duration:Number.isFinite(raw.duration) ? Math.max(0,raw.duration) : 0, isAd:raw.isAd === true,
      artwork:raw.artwork.slice(0,12).filter(i => {
        try { return new URL(i.url).protocol === 'https:' && i.url.length < 8000; } catch { return false; }
      }).map(i => ({url:i.url, w:Math.max(0,Number(i.w)||0), h:Math.max(0,Number(i.h)||0)}))};
  }
  if (raw.type === 'clock' && Number.isFinite(raw.t) && Number.isFinite(raw.rate)) return {...common,
    t:Math.max(0,raw.t), rate:raw.rate, paused:raw.paused === true, buffering:raw.buffering === true};
  if (raw.type === 'captionTracks' && Array.isArray(raw.tracks)) return {...common, tracks: raw.tracks.slice(0,100)
    .filter(t => t && typeof t.id === 'string' && TRACK_ID.test(t.id) && typeof t.lang === 'string')
    .map(t => ({id:t.id, lang:str(t.lang,24), name:str(t.name,80) || t.lang, ...(t.kind === 'asr' ? {kind:'asr'} : {})}))};
  if (raw.type === 'liveCaption') return {...common,text:str(raw.text,10000)};
  if (raw.type === 'cues' && ['yt-captions','ytm-lyrics','lrclib','dom'].includes(raw.source) &&
    ['manual','asr','lyrics'].includes(raw.kind) && Array.isArray(raw.cues) && raw.cues.length <= 20000) {
    const cues = NPParsers.normalizeCues(raw.cues.filter(c => c && typeof c === 'object')
      .map(c => ({s:c.s,e:c.e,text:str(c.text,10000)})));
    const message = {...common,source:raw.source,kind:raw.kind,lang:str(raw.lang,40),synced:raw.synced === true,cues,
      ...(raw.slot === 2 ? {slot:2} : {})};
    return JSON.stringify(message).length < 900000 ? message : null;
  }
  return null;
}
async function lyrics(query) {
  if (!query || typeof query.title !== 'string' || typeof query.artist !== 'string' ||
    query.title.length > 1000 || query.artist.length > 1000 || !Number.isFinite(query.duration) || query.duration <= 0) return {cues:[]};
  const key = JSON.stringify([query.title,query.artist,query.album,query.duration]);
  const hit = lyricCache.get(key);
  if (hit && Date.now() - hit.at < 300000) return hit.result;
  if (inflight.has(key)) return inflight.get(key);
  const work = (async () => {
    let result = {cues:[]};
    // Retry with localized/decorative suffixes removed, e.g. "The Chainsmokers(체인스모커스)",
    // "Song (Official Audio)", "Artist - Topic".
    const clean = value => value.replace(/\s*[([（【][^)\]）】]*[)\]）】]/g, '').replace(/\s+-\s+Topic$/i, '').trim();
    const attempts = [[query.title, query.artist]];
    const cleaned = [clean(query.title) || query.title, clean(query.artist) || query.artist];
    if (cleaned[0] !== query.title || cleaned[1] !== query.artist) attempts.push(cleaned);
    for (const [title, artist] of attempts) {
      try {
        const params = new URLSearchParams({track_name:title,artist_name:artist,duration:String(Math.round(query.duration))});
        if (typeof query.album === 'string' && query.album) params.set('album_name',query.album.slice(0,1000));
        const response = await fetch(`https://lrclib.net/api/get?${params}`, {signal:AbortSignal.timeout(7000), credentials:'omit'});
        if (response.ok) {
          const data = await response.json();
          if (Number.isFinite(data.duration) && Math.abs(data.duration - query.duration) <= 3 && typeof data.syncedLyrics === 'string' && data.syncedLyrics.length < 500000) {
            result = {cues:NPParsers.parseLRC(data.syncedLyrics, query.duration)};
          }
        }
      } catch { /* Missing lyrics/rate limiting never affects playback. */ }
      if (result.cues.length) break;
    }
    lyricCache.set(key, {at:Date.now(),result});
    while (lyricCache.size > 24) lyricCache.delete(lyricCache.keys().next().value);
    return result;
  })();
  inflight.set(key, work);
  try { return await work; } finally { inflight.delete(key); }
}
chrome.runtime.onMessage.addListener((request, sender, respond) => {
  if (sender.id !== chrome.runtime.id || sender.frameId !== 0 || !sender.tab || !allowed(sender.url)) return;
  if (request?.op === 'lyrics') {
    if (new URL(sender.url).hostname !== 'music.youtube.com') return;
    lyrics(request.query).then(respond, () => respond({cues:[]})); return true;
  }
  if (request?.op !== 'publish') return;
  const message = sanitize(request.message);
  if (!message) return;
  const id = sender.tab.id;
  if (message.type === 'gone') states.delete(id);
  else {
    let state = states.get(id);
    if (message.type === 'track' && state?.track?.videoId !== message.videoId) state = {};
    if (!state) state = {};
    if (message.type !== 'track' && state.track?.videoId !== message.videoId) return;
    if (state.track?.isAd && ['cues','liveCaption'].includes(message.type) && message.text !== '') return;
    state[message.type === 'cues' && message.slot === 2 ? 'cues2' : message.type] = message; states.set(id,state);
    if (message.type === 'track' && message.isAd) delete state.cues;
  }
  nativeSend(id,message);
  // Host ACK is not part of v1. Successful incoming tab state permits a
  // connection attempt, but does not reset failed-host backoff.
  if (!port && !retry) connect();
  respond({ok:true});
});
chrome.tabs.onRemoved.addListener(id => {
  if (states.has(id)) nativeSend(id,{type:'gone'});
  states.delete(id);
});
chrome.tabs.onUpdated.addListener((id, change) => {
  let leftWatch = change.url && !allowed(change.url);
  if (change.url && allowed(change.url)) {
    const url = new URL(change.url);
    leftWatch = url.hostname === 'www.youtube.com' && (url.pathname !== '/watch' || !url.searchParams.has('v'));
  }
  if (leftWatch && states.has(id)) {
    states.delete(id); nativeSend(id,{type:'gone'});
  }
});
chrome.action.onClicked.addListener(tab => {
  if (tab.id && allowed(tab.url)) {
    void toTab(tab.id,{type:'requestSnapshot'});
    if (!port && !retry) connect();
  }
});
chrome.alarms.onAlarm.addListener(alarm => {
  if (alarm.name !== RETRY_ALARM || port) return;
  if (retry) { clearTimeout(retry); retry = null; }
  connect();
});
connect();
