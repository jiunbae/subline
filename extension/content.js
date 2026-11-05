(() => {
  'use strict';
  const CHANNEL = 'nowplaying-v1';
  const music = location.hostname === 'music.youtube.com';
  let track = null, main = null, video = null, cues = null, signature = '', captionText = '';
  let visible = true, buffering = false, tick = null, refreshTimer = null, lyricTimer = null;
  let playerObserver = null, barObserver = null, captionObserver = null;
  let observedPlayer = null, observedBar = null, observedCaptions = null;
  let generation = 0, lyricsAttempt = '', lyricsRetries = 0;
  // Per video: caption tracks chosen in the app (slot 1 = main, 2 = secondary) and the last sent track list.
  let preferredTrack = '', secondaryTrack = '', secondaryCues = null, tracksSig = '';
  const cache = new Map(); // Normalized cues only; no request URLs or credentials.
  const send = message => { try { chrome.runtime.sendMessage({op: 'publish', message}).catch(() => {}); } catch {} };
  const askMain = (kind, extra = {}) => window.postMessage({channel: CHANNEL, direction: 'to-main', kind, ...extra}, location.origin);
  const emptyCues = () => ({type: 'cues', videoId: track.videoId, source: music ? 'ytm-lyrics' : 'yt-captions',
    kind: music ? 'lyrics' : 'manual', synced: true, cues: []});
  function emitCues(value) {
    if (!track || track.isAd || value.videoId !== track.videoId) return;
    cues = value;
    if (value.cues.length) {
      const key = [track.videoId, value.lang || '', value.kind, value.source, 1].join('|');
      cache.delete(key); cache.set(key, {at: Date.now(), value});
      while (cache.size > 8) cache.delete(cache.keys().next().value);
    }
    send(value);
    if (value.cues.length && captionText) {
      captionText = ''; send({type: 'liveCaption', videoId: track.videoId, text: ''});
    }
  }
  function clock() {
    if (!track || !video) return;
    send({type: 'clock', videoId: track.videoId, t: Number.isFinite(video.currentTime) ? video.currentTime : 0,
      rate: Number.isFinite(video.playbackRate) ? video.playbackRate : 1, paused: video.paused || video.ended,
      buffering});
  }
  function updateTimer() {
    clearInterval(tick); tick = null;
    // Drift correction only: play/pause/seek/rate/buffering are sent immediately and the app
    // extrapolates with a monotonic clock, so 5 s keeps browser/IPC wakeups 80% below a 1 s tick.
    if (visible && video && !video.paused && !video.ended) tick = setInterval(clock, 5000);
  }
  function onVideo(event) {
    if (event.type === 'waiting' || event.type === 'seeking' || event.type === 'stalled') buffering = true;
    if (['playing', 'seeked', 'canplay', 'pause', 'ended'].includes(event.type)) buffering = false;
    if (['loadedmetadata', 'durationchange', 'emptied'].includes(event.type)) scheduleRefresh();
    clock(); updateTimer();
  }
  const events = ['play','pause','seeking','seeked','ratechange','waiting','playing','stalled','canplay','ended','loadedmetadata','durationchange','emptied'];
  function attachVideo() {
    const next = document.querySelector('video.html5-main-video') || document.querySelector('video');
    if (next === video) return;
    if (video) for (const e of events) video.removeEventListener(e, onVideo);
    video = next; buffering = video ? video.readyState < 3 && !video.paused : false;
    if (video) for (const e of events) video.addEventListener(e, onVideo);
    updateTimer();
  }
  function liveCaption() {
    if (!track || track.isAd || cues?.cues?.length) return;
    // The player briefly shows the track name ("English (auto-generated)", "Click ⚙ for settings")
    // in the caption area when CC turns on; that is not a caption.
    const names = new Set((captionTrackList() || []).map(t => t.name));
    const banner = /click .*for settings|설정하려면|設定/i;
    const text = [...document.querySelectorAll('.ytp-caption-segment')].map(n => n.textContent.trim())
      .filter(line => line && !names.has(line) && !banner.test(line)).join('\n').trim();
    if (text !== captionText) { captionText = text; send({type:'liveCaption', videoId:track.videoId, text}); }
  }
  function observers() {
    const player = document.querySelector('#movie_player') || document.querySelector('ytmusic-player');
    if (player !== observedPlayer) {
      playerObserver?.disconnect(); observedPlayer = player;
      if (player) {
        playerObserver = new MutationObserver(scheduleRefresh);
        playerObserver.observe(player, {attributes: true, attributeFilter: ['class'], childList: true});
      }
    }
    const bar = document.querySelector(music ? 'ytmusic-player-bar' : 'ytd-watch-metadata');
    if (bar !== observedBar) {
      barObserver?.disconnect(); observedBar = bar;
      if (bar) {
        barObserver = new MutationObserver(scheduleRefresh);
        if (music) {
          barObserver.observe(bar, {childList:true});
          for (const node of bar.querySelectorAll('.title, .byline, img')) {
            barObserver.observe(node, {subtree:true, childList:true, characterData:true, attributes:true, attributeFilter:['src']});
          }
        } else barObserver.observe(bar, {subtree:true, childList:true, characterData:true});
      }
    }
    const container = document.querySelector('.ytp-caption-window-container');
    if (container !== observedCaptions) {
      captionObserver?.disconnect(); observedCaptions = container;
      if (container) {
        captionObserver = new MutationObserver(liveCaption);
        captionObserver.observe(container, {subtree:true, childList:true, characterData:true});
      }
    }
  }
  async function lrclib(id, epoch) {
    if (!track || track.videoId !== id || track.isAd || !music || cues?.cues?.length) return;
    const query = {title:track.title, artist:track.artist, album:track.album || '', duration:track.duration};
    if (!query.title || !query.artist || query.duration <= 0) return;
    try {
      const result = await chrome.runtime.sendMessage({op:'lyrics', query});
      if (epoch !== generation || track?.videoId !== id || track.isAd || cues?.cues?.length) return;
      // No companion app yet: don't query anyone; try again when the app asks for a snapshot.
      if (result?.offline) { lyricsAttempt = ''; return; }
      // Network/server trouble: retry later (20 s, 60 s), then fall back as for "not found".
      if (result?.transient && lyricsRetries < 2) {
        const delay = [20000, 60000][lyricsRetries++];
        clearTimeout(lyricTimer);
        lyricTimer = setTimeout(() => void lrclib(id, epoch), delay);
        return;
      }
      if (result?.cues?.length) emitCues({type:'cues', videoId:id, source:'lrclib', kind:'lyrics', synced:true, cues:result.cues});
      else askMain('lyrics', {videoId:id}); // YTM's own (usually unsynced) lyrics as the last resort
    } catch { if (epoch === generation && track?.videoId === id && !cues?.cues?.length) askMain('lyrics', {videoId:id}); }
  }
  function captionTrackList() {
    const list = !music && track && main?.videoId === track.videoId ? main.data?.captionTracks : null;
    return Array.isArray(list) ? list : null;
  }
  function sendCaptionTracks(force = false) {
    const tracks = captionTrackList();
    if (!tracks || track.isAd) return;
    // Translation targets only make sense when the video has a caption track to translate.
    const translations = tracks.length && Array.isArray(main.data?.translationLanguages) ? main.data.translationLanguages : [];
    const sig = JSON.stringify([tracks, translations.length]);
    if (!force && sig === tracksSig) return;
    tracksSig = sig;
    send({type:'captionTracks', videoId:track.videoId, tracks, translations});
  }
  function beginLyrics() {
    if (!music || !track || track.isAd || !track.title || !track.artist || track.duration <= 0 || lyricsAttempt === track.videoId) return;
    lyricsAttempt = track.videoId;
    // Synced LRCLIB first: YTM web only serves unsynced lyrics (verified 2026-11 while logged in).
    const id = track.videoId, epoch = generation;
    clearTimeout(lyricTimer);
    void lrclib(id, epoch);
  }
  function refresh() {
    refreshTimer = null;
    attachVideo(); observers();
    const next = music ? NPAdapters.readYTM(main, video) : NPAdapters.readYT(main, video);
    // Metadata not ready yet (or a non-playable page such as the Premium upsell): wait, don't publish.
    if (next && !next.title && !next.isAd) { askMain('metadata'); return; }
    if (!next) {
      if (track) send({type:'gone'});
      track = null; cues = null; signature = ''; generation++; clearTimeout(lyricTimer);
      askMain('metadata'); return;
    }
    const changed = next.videoId !== track?.videoId;
    const adChanged = next.isAd !== track?.isAd;
    track = next;
    if (changed) {
      generation++; lyricsAttempt = ''; lyricsRetries = 0; captionText = ''; cues = emptyCues(); preferredTrack = ''; secondaryTrack = ''; secondaryCues = null; tracksSig = '';
      // Short TTL also avoids persisting changing/live captions across navigation.
      const cached = [...cache.values()].reverse().find(c => c.value.videoId === next.videoId && Date.now() - c.at < 300000);
      if (cached) cues = cached.value;
      clearTimeout(lyricTimer);
    }
    const newSignature = JSON.stringify(track);
    if (signature !== newSignature) { signature = newSignature; send({type:'track', ...track}); }
    if (changed || adChanged) {
      clock();
      if (!track.isAd) { emitCues(cues || emptyCues()); liveCaption(); }
      else { captionText = ''; send({type:'liveCaption', videoId:track.videoId, text:''}); }
    }
    sendCaptionTracks();
    beginLyrics();
    askMain('metadata');
  }
  function scheduleRefresh() {
    if (!refreshTimer) refreshTimer = setTimeout(refresh, 100);
  }
  window.addEventListener('message', event => {
    const m = event.data;
    if (event.source !== window || event.origin !== location.origin || m?.channel !== CHANNEL || m.direction !== 'from-main') return;
    if (m.kind === 'metadata') {
      const serialized = JSON.stringify(m);
      if (serialized.length > 200000 || typeof m.videoId !== 'string') return;
      if (JSON.stringify(main) !== serialized) { main = m; scheduleRefresh(); }
      return;
    }
    if (!track || track.isAd || m.videoId !== track.videoId || !Array.isArray(m.cues)) return;
    // Cues are already normalized in the MAIN-world bridge (incl. ASR rolling dedupe) and
    // re-sanitized in the service worker. parsers.js is not available here: Chrome injects a
    // file listed in several content_scripts entries only once per frame (into MAIN first).
    const normalized = m.cues.filter(c => c && Number.isFinite(c.s) && typeof c.text === 'string' && c.text)
      .slice(0, 20000).map(c => ({s: c.s, ...(Number.isFinite(c.e) ? {e: c.e} : {}), text: c.text.slice(0, 10000)}));
    const lang = typeof m.lang === 'string' ? m.lang.slice(0,24) : '';
    const key = m.translated ? 'x-' + lang : lang + (m.trackKind === 'asr' ? ':asr' : '');
    if (m.kind === 'captions' && secondaryTrack && key === secondaryTrack && key !== preferredTrack) {
      if (!normalized.length) return;
      secondaryCues = {type:'cues', videoId:track.videoId, source:'yt-captions', lang:m.lang.slice(0,40),
        kind:m.trackKind === 'asr' ? 'asr' : 'manual', synced:true, slot:2, trackId:key, cues:normalized};
      send(secondaryCues);
      return;
    }
    // Once the user picked a track in the app, ignore the player's other fetches (e.g. restoring its own track).
    if (m.kind === 'captions' && preferredTrack && key !== preferredTrack) return;
    if (m.kind === 'captions' && normalized.length) emitCues({type:'cues', videoId:track.videoId,
      source:'yt-captions', lang:typeof m.lang === 'string' ? m.lang.slice(0,40) : '', trackId:key,
      kind:m.trackKind === 'asr' ? 'asr' : 'manual', synced:true, cues:normalized});
    if (m.kind === 'lyrics') {
      clearTimeout(lyricTimer);
      if (normalized.length && !cues?.cues?.length) emitCues({type:'cues', videoId:track.videoId, source:'ytm-lyrics',
        kind:'lyrics', synced:m.synced !== false, cues:normalized});
    }
  });
  chrome.runtime.onMessage.addListener((message, sender, respond) => {
    if (sender.id !== chrome.runtime.id) return;
    if (message.type === 'visibility') {
      // Answer only a real change (hidden → visible) with a clock; repeated messages must not echo.
      const was = visible; visible = message.visible !== false; updateTimer();
      if (visible && !was) clock();
    }
    if (message.type === 'requestSnapshot') {
      refresh();
      if (track) { send({type:'track', ...track}); clock(); if (!track.isAd) { send(cues || emptyCues()); if (secondaryCues) send(secondaryCues); sendCaptionTracks(true); } }
    }
    if (message.type === 'connectCaptions' && track) askMain('connectCaptions', {videoId: track.videoId});
    if (message.type === 'selectCaptions' && typeof message.trackId === 'string' && track && !music) {
      const slot = message.slot === 2 ? 2 : 1, id = message.trackId;
      if (slot === 2 && id === '') {
        secondaryTrack = ''; secondaryCues = null;
        send({type:'cues', videoId:track.videoId, source:'yt-captions', kind:'manual', synced:true, slot:2, cues:[]});
      } else if (/^[A-Za-z0-9_-]{1,24}(:asr)?$/.test(id)) {
        if (slot === 2) { secondaryTrack = id; secondaryCues = null; } else preferredTrack = id;
        askMain('selectCaptions', {trackId: id, videoId: track.videoId});
      }
    }
    if (message.type === 'cmd' && video && track && (!message.videoId || message.videoId === track.videoId)) {
      if (message.action === 'play' || (message.action === 'toggle' && video.paused)) void video.play().catch(() => {});
      else if (message.action === 'pause' || message.action === 'toggle') video.pause();
      else if (message.action === 'seek' && Number.isFinite(message.t)) video.currentTime = Math.max(0, Math.min(message.t, Number.isFinite(video.duration) ? video.duration : message.t));
      else if (message.action === 'next' || message.action === 'prev') NPAdapters.skip(music, message.action === 'prev');
      clock();
    }
    respond({ok:true});
  });
  for (const event of ['yt-navigate-finish','yt-page-data-updated','yt-player-updated','ytmusic-player-state-changed','popstate']) {
    window.addEventListener(event, scheduleRefresh, true);
  }
  // Bounded startup discovery; site events and narrow observers take over.
  for (const delay of [0, 500, 1500, 4000]) setTimeout(scheduleRefresh, delay);
  document.addEventListener('DOMContentLoaded', scheduleRefresh, {once:true});
})();
