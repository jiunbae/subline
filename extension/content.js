(() => {
  'use strict';
  const CHANNEL = 'subline-v1';
  const music = location.hostname === 'music.youtube.com';
  let track = null, main = null, video = null, cues = null, signature = '', captionText = '';
  let visible = true, buffering = false, tick = null, refreshTimer = null;
  let playerObserver = null, barObserver = null, captionObserver = null;
  let observedPlayer = null, observedBar = null, observedCaptions = null, progressObserver = null, observedProgress = null;
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
  // YouTube Music can play queued songs back to back in one media stream: the <video> clock keeps
  // counting across songs. Its own progress bar is per song, so on Music the song's position is the
  // media time minus an offset learned from that bar. The bar shows whole seconds, so the smallest
  // (media - bar) seen is the offset; a jump of more than 1.5 s (seek, next song) starts over.
  let offset = 0, offsetFor = '';
  function songBar() {
    const bar = music ? document.querySelector('ytmusic-player-bar #progress-bar') : null;
    const now = Number(bar?.getAttribute('aria-valuenow') ?? bar?.value), max = Number(bar?.getAttribute('aria-valuemax'));
    return Number.isFinite(now) && Number.isFinite(max) && max > 0 && now >= 0 && now <= max + 1 ? {now, max} : null;
  }
  function songTime() {
    const media = Number.isFinite(video?.currentTime) ? video.currentTime : 0;
    if (!music) return media;
    if (offsetFor !== track?.videoId) { offsetFor = track?.videoId || ''; offset = 0; }
    const bar = songBar();
    if (bar) {
      const candidate = Math.max(0, media - bar.now);
      if (Math.abs(candidate - offset) > 1.5 || candidate < offset) offset = candidate;
    }
    return Math.max(0, media - offset);
  }
  function clock() {
    if (!track || !video) return;
    send({type: 'clock', videoId: track.videoId, t: songTime(),
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
    // Music: the progress bar re-anchors the song clock when songs share one media stream (see songTime).
    const progress = music ? document.querySelector('ytmusic-player-bar #progress-bar') : null;
    if (progress !== observedProgress) {
      progressObserver?.disconnect(); observedProgress = progress;
      if (progress) {
        progressObserver = new MutationObserver(() => {
          if (!track || !video || track.isAd) return;
          const before = offset, id = offsetFor;
          songTime();
          if (id === offsetFor && Math.abs(offset - before) > 0.5) clock();
        });
        progressObserver.observe(progress, {attributes: true, attributeFilter: ['aria-valuenow', 'aria-valuemax']});
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
  function refresh() {
    refreshTimer = null;
    attachVideo(); observers();
    const next = music ? NPAdapters.readYTM(main, video) : NPAdapters.readYT(main, video);
    // Metadata not ready yet (or a non-playable page such as the Premium upsell): wait, don't publish.
    if (next && !next.title && !next.isAd) { askMain('metadata'); return; }
    if (!next) {
      if (track) send({type:'gone'});
      track = null; cues = null; signature = '';
      askMain('metadata'); return;
    }
    const changed = next.videoId !== track?.videoId;
    const adChanged = next.isAd !== track?.isAd;
    track = next;
    if (changed) {
      captionText = ''; cues = emptyCues(); preferredTrack = ''; secondaryTrack = ''; secondaryCues = null; tracksSig = '';
      // Short TTL also avoids persisting changing/live captions across navigation.
      const cached = [...cache.values()].reverse().find(c => c.value.videoId === next.videoId && Date.now() - c.at < 300000);
      if (cached) cues = cached.value;
     
    }
    const newSignature = JSON.stringify(track);
    if (signature !== newSignature) { signature = newSignature; send({type:'track', ...track}); }
    if (changed || adChanged) {
      clock();
      if (!track.isAd) {
        emitCues(cues || emptyCues()); liveCaption();
        // The placeholder goes first (the app starts LRCLIB on it); the page's own lyrics follow.
        if (music && changed && !cues?.cues?.length) askMain('lyrics', {videoId: track.videoId});
      }
      else { captionText = ''; send({type:'liveCaption', videoId:track.videoId, text:''}); }
    }
    sendCaptionTracks();
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
    if (m.kind === 'lyrics') {
      if (!music || !m.cues.length) return; // nothing from the page: the placeholder stands
      const lines = m.cues.filter(c => c && Number.isFinite(c.s) && typeof c.text === 'string').slice(0, 5000)
        .map(c => ({s: c.s, ...(Number.isFinite(c.e) ? {e: c.e} : {}), text: c.text.slice(0, 2000)}));
      if (lines.some(c => c.text)) emitCues({type:'cues', videoId:track.videoId, source:'ytm-lyrics', kind:'lyrics',
        synced: m.synced === true, cues: lines});
      return;
    }
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
      else if (message.action === 'seek' && Number.isFinite(message.t)) {
        const target = Math.max(0, message.t + (music ? offset : 0));
        video.currentTime = Math.min(target, Number.isFinite(video.duration) ? video.duration : target);
      }
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
