import test from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import {readFileSync} from 'node:fs';
import {webcrypto} from 'node:crypto';

const root = new URL('../', import.meta.url);
const source = file => readFileSync(new URL(file, root), 'utf8');
const plain = value => JSON.parse(JSON.stringify(value));
const VIDEO = 'dQw4w9WgXcQ';
const CHANNEL = 'nowplaying-v1';
const json3 = {events:[{tStartMs:1000, dDurationMs:2000, segs:[{utf8:'Hello world.'}]}]};
// Drain promise continuations created by fetch/clone/text and the caption command queue.
const flush = async () => { for (let i = 0; i < 20; i++) await Promise.resolve(); };

// translationQuirk: real YouTube behavior observed 2026-11 — while a translation is active, a plain native
// selection is ignored and only the track object from the player's track list is accepted.
function harness({ccOn = true, track = {languageCode:'en'}, translationQuirk = false, refuseTranslations = false} = {}) {
  const messages = [], calls = [], clicks = [], fetches = [], timers = [];
  const listeners = new Map();
  const location = new URL(`https://www.youtube.com/watch?v=${VIDEO}`);
  const id = () => location.searchParams.get('v');
  let current = plain(track), pressed = ccOn, now = 0, nextTimer = 1;
  const tracks = [
    {languageCode:'en', name:{simpleText:'English'}, vss_id:'.en'},
    {languageCode:'en', name:{simpleText:'English duplicate'}, vss_id:'.en.duplicate'},
    {languageCode:'en', kind:'asr', name:{runs:[{text:'English '}, {text:'(auto-generated)'}]}, vss_id:'a.en'},
    {languageCode:'ja', name:{simpleText:'Japanese'}, vss_id:'.ja'},
    {languageCode:'invalid code', name:{simpleText:'Invalid'}, vss_id:'.invalid'},
  ];
  const translations = [
    {languageCode:'ko', languageName:{simpleText:'Korean'}},
    {languageCode:'ja', languageName:{runs:[{text:'Japanese'}]}},
    {languageCode:'invalid code', languageName:{simpleText:'Invalid'}},
  ];
  const button = {
    disabled:false, isConnected:true,
    getAttribute(name) {
      if (name === 'aria-pressed') return String(pressed);
      if (name === 'aria-disabled') return 'false';
      return null;
    },
    click() { pressed = !pressed; clicks.push({videoId:id(), on:pressed}); },
  };
  const response = () => ({
    ok:true, status:200, headers:{get:() => null},
    clone:() => ({text:async () => JSON.stringify(json3)}),
    json:async () => plain(json3),
  });
  const window = {
    addEventListener(type, fn) {
      if (!listeners.has(type)) listeners.set(type, []);
      listeners.get(type).push(fn);
    },
    postMessage(data, origin) {
      messages.push(plain(data));
      dispatch(data, {origin});
    },
    fetch:async (input, options) => {
      const url = new URL(typeof input === 'string' || input instanceof URL ? input : input.url, location);
      fetches.push({url:url.href, options});
      if (refuseTranslations && url.searchParams.get('tlang')) return {ok:false, status:429, headers:{get:() => null}, clone() { return this; }, text:async () => 'rate limited'};
      return response();
    },
  };
  function dispatch(data, {origin = location.origin, source = window} = {}) {
    for (const fn of listeners.get('message') || []) fn({data, origin, source});
  }
  const player = {
    classList:{contains:() => false},
    getVideoData:() => ({video_id:id(), title:'Example video', author:'Example artist'}),
    getPlayerResponse:() => ({
      videoDetails:{videoId:id(), title:'Example video', author:'Example artist', lengthSeconds:'180', thumbnail:{thumbnails:[]}},
      captions:{playerCaptionsTracklistRenderer:{captionTracks:tracks, translationLanguages:translations}},
    }),
    getOption(module, option) {
      assert.equal(module, 'captions');
      if (option === 'tracklist') return plain(tracks);
      assert.equal(option, 'track');
      // YouTube returns a full track, but only accepts a plain selection in setOption.
      return {...plain(current), vss_id:'.mock-full-track'};
    },
    setOption(module, option, value) {
      assert.equal(module, 'captions'); assert.equal(option, 'track');
      const allowedKeys = ['languageCode', 'kind', 'translationLanguage'];
      const plainForm = !!value?.languageCode && Object.keys(value).every(key => allowedKeys.includes(key)) &&
        (!value.translationLanguage || Object.keys(value.translationLanguage).every(key => key === 'languageCode'));
      const listedForm = !!value?.vss_id && !value.translationLanguage;
      const accepted = translationQuirk && current.translationLanguage
        ? listedForm // while translated: only the listed native track object gets out
        : plainForm; // otherwise ignore objects carrying vss_id
      calls.push({videoId:id(), track:plain(value), accepted});
      if (!accepted) return;
      current = listedForm ? {languageCode:value.languageCode, ...(value.kind === 'asr' ? {kind:'asr'} : {})} : plain(value);
      // Simulate the player fetching this track through the bridge's real fetch hook.
      const params = new URLSearchParams({v:id(), lang:current.languageCode, fmt:'json3'});
      if (current.kind === 'asr') params.set('kind', 'asr');
      if (current.translationLanguage) params.set('tlang', current.translationLanguage.languageCode);
      void window.fetch(`/api/timedtext?${params}`);
    },
  };
  class XMLHttpRequest {
    constructor() { this.listeners = new Map(); }
    open(method, url) { this.url = url; }
    addEventListener(type, fn) { this.listeners.set(type, fn); }
    send() {
      this.status = 200;
      this.responseType = '';
      this.responseText = JSON.stringify(json3);
      this.listeners.get('load')?.();
    }
  }
  const context = vm.createContext({
    window, location, URL, URLSearchParams, XMLHttpRequest,
    document:{cookie:'', querySelector:selector => selector === '#movie_player' ? player :
      selector === '.ytp-subtitles-button' ? button : null},
    setTimeout(fn, delay = 0) {
      const timer = {id:nextTimer++, at:now + delay, fn};
      timers.push(timer); return timer.id;
    },
    clearTimeout(timerId) {
      const index = timers.findIndex(timer => timer.id === timerId);
      if (index !== -1) timers.splice(index, 1);
    },
    crypto:webcrypto, TextEncoder, AbortSignal, structuredClone,
  });
  // Execute the shipped scripts unmodified, including the installed event/fetch/XHR hooks.
  for (const file of ['parsers.js', 'bridge.js']) vm.runInContext(source(file), context, {filename:file});

  return {
    messages, calls, clicks, fetches, window, XMLHttpRequest,
    get track() { return plain(current); },
    get ccOn() { return pressed; },
    get pendingTimers() { return timers.length; },
    send(kind, payload = {}) {
      dispatch({channel:CHANNEL, direction:'to-main', kind, ...payload});
    },
    navigate(videoId) {
      location.search = `?v=${videoId}`;
      current = {languageCode:'en'}; pressed = true;
    },
    async drain() {
      // No real sleeps: advance one deadline, flush its continuations, then discover the next.
      for (let steps = 0; steps < 100; steps++) {
        await flush();
        if (!timers.length) return;
        timers.sort((a, b) => a.at - b.at || a.id - b.id);
        const timer = timers.shift(); now = timer.at; timer.fn();
      }
      assert.fail('Bridge did not settle after 100 fake timers');
    },
  };
}

function captions(h) { return h.messages.filter(message => message.kind === 'captions'); }
function assertCaption(message, {lang, trackKind, translated}) {
  assert.equal(message.channel, CHANNEL);
  assert.equal(message.direction, 'from-main');
  assert.equal(message.videoId, VIDEO);
  assert.equal(message.lang, lang);
  assert.equal(message.trackKind, trackKind);
  assert.equal(message.translated, translated);
  assert.deepEqual(message.cues, [{s:1, e:3, text:'Hello world.'}]);
}

test('bridge captures manual JSON3 timedtext fetched by the page', async () => {
  const h = harness();
  await h.window.fetch(`/api/timedtext?v=${VIDEO}&lang=en&fmt=json3`); await h.drain();
  assert.equal(captions(h).length, 1);
  assertCaption(captions(h)[0], {lang:'en', trackKind:'manual', translated:false});
});

test('bridge captures translated timedtext under the target language', async () => {
  const h = harness();
  // ASR is the source; translated output must still be classified as manual.
  await h.window.fetch(`/api/timedtext?v=${VIDEO}&lang=en&kind=asr&tlang=ko&fmt=json3`); await h.drain();
  assert.equal(captions(h).length, 1);
  assertCaption(captions(h)[0], {lang:'ko', trackKind:'manual', translated:true});
});

test('bridge classifies original ASR timedtext separately', async () => {
  const h = harness();
  await h.window.fetch(`/api/timedtext?v=${VIDEO}&lang=en&kind=asr&fmt=json3`); await h.drain();
  assert.equal(captions(h).length, 1);
  assertCaption(captions(h)[0], {lang:'en', trackKind:'asr', translated:false});
});

test('bridge ignores timedtext for another video and another origin', async () => {
  const h = harness();
  await h.window.fetch('/api/timedtext?v=BBBBBBBBBBB&lang=en&fmt=json3');
  await h.window.fetch(`https://example.com/api/timedtext?v=${VIDEO}&lang=en&fmt=json3`);
  await h.drain();
  assert.equal(h.fetches.length, 2); // Requests still reach the original fetch.
  assert.deepEqual(captions(h), []);
});

test('bridge also captures timedtext through the installed XHR hook', async () => {
  const h = harness(), xhr = new h.XMLHttpRequest();
  xhr.open('GET', `/api/timedtext?v=${VIDEO}&lang=en&fmt=json3`); xhr.send(); await h.drain();
  assert.equal(captions(h).length, 1);
  assertCaption(captions(h)[0], {lang:'en', trackKind:'manual', translated:false});
});

test('bridge metadata deduplicates caption IDs and exposes translation targets', async () => {
  const h = harness(); h.send('metadata'); await h.drain();
  assert.equal(h.messages.length, 1);
  const message = h.messages[0];
  assert.equal(message.kind, 'metadata'); assert.equal(message.videoId, VIDEO);
  assert.deepEqual(message.data.captionTracks, [
    {id:'en', lang:'en', name:'English'},
    {id:'en:asr', lang:'en', name:'English (auto-generated)', kind:'asr'},
    {id:'ja', lang:'ja', name:'Japanese'},
  ]);
  assert.deepEqual(message.data.translationLanguages, [
    {id:'x-ko', lang:'ko', name:'Korean', kind:'translation'},
    {id:'x-ja', lang:'ja', name:'Japanese', kind:'translation'},
  ]);
});

test('selectCaptions uses plain track objects and restores the original track and CC off state', async () => {
  const h = harness({ccOn:false});
  h.send('selectCaptions', {videoId:VIDEO, trackId:'ja'}); await h.drain();
  assert.deepEqual(h.clicks.map(click => click.on), [true, false]);
  assert.deepEqual(h.calls.map(call => call.track), [{languageCode:'ja'}, {languageCode:'en'}]);
  assert.ok(h.calls.every(call => call.accepted));
  assert.ok(captions(h).some(message => message.lang === 'ja'));
  assert.deepEqual(h.track, {languageCode:'en'}); assert.equal(h.ccOn, false);
});

test('selecting x-ko restores the user\'s existing Japanese auto-translation with CC on', async () => {
  const original = {languageCode:'en', translationLanguage:{languageCode:'ja'}};
  const h = harness({ccOn:true, track:original});
  h.send('selectCaptions', {videoId:VIDEO, trackId:'x-ko'}); await h.drain();
  assert.deepEqual(h.calls.map(call => call.track), [
    {languageCode:'en', translationLanguage:{languageCode:'ko'}}, original,
  ]);
  assert.ok(h.calls.every(call => call.accepted));
  assert.ok(captions(h).some(message => message.lang === 'ko' && message.translated));
  assert.deepEqual(h.track, original); assert.equal(h.ccOn, true);
  assert.deepEqual(h.clicks, []);
});

test('a queued caption command for video A never changes video B after navigation', async () => {
  const h = harness();
  h.send('selectCaptions', {videoId:VIDEO, trackId:'ja'});
  h.send('selectCaptions', {videoId:VIDEO, trackId:'x-ko'});
  await flush();
  // The first command has changed A and is waiting; the second is still queued.
  assert.deepEqual(h.calls.map(call => call.track), [{languageCode:'ja'}]);
  assert.ok(h.pendingTimers > 0);
  const nextVideo = 'BBBBBBBBBBB'; h.navigate(nextVideo); await h.drain();
  assert.ok(h.calls.every(call => call.videoId === VIDEO));
  assert.deepEqual(h.track, {languageCode:'en'});
  // Prove the queue drained and can accept fresh B commands, rather than silently hanging.
  h.send('selectCaptions', {videoId:nextVideo, trackId:'ja'}); await h.drain();
  assert.deepEqual(h.calls.filter(call => call.videoId === nextVideo).map(call => call.track), [
    {languageCode:'ja'}, {languageCode:'en'},
  ]);
});

test('connectCaptions restores CC off after briefly enabling it', async () => {
  const h = harness({ccOn:false});
  h.send('connectCaptions', {videoId:VIDEO}); await h.drain();
  assert.deepEqual(h.clicks.map(click => click.on), [true, false]);
  assert.equal(h.ccOn, false); assert.deepEqual(h.track, {languageCode:'en'});
  assert.deepEqual(h.calls, []);
});

test('leaving an active auto-translation for a native track falls back to the listed track object', async () => {
  const original = {languageCode:'en', translationLanguage:{languageCode:'ja'}};
  const h = harness({ccOn:true, track:original, translationQuirk:true});
  h.send('selectCaptions', {videoId:VIDEO, trackId:'ja'}); await h.drain();
  const tried = h.calls.map(call => call.accepted);
  assert.equal(tried[0], false);                       // the plain form is ignored while translated
  assert.ok(h.calls.some(call => call.accepted && call.track.vss_id === '.ja'));
  assert.ok(captions(h).some(message => message.lang === 'ja' && !message.translated));
  assert.deepEqual(h.track, original);                 // the user's translation comes back afterwards
});

test('switching to another auto-translation while one is active steps back to the native track first', async () => {
  const h = harness({ccOn:true, track:{languageCode:'en', translationLanguage:{languageCode:'ja'}}, translationQuirk:true});
  h.send('selectCaptions', {videoId:VIDEO, trackId:'x-ko'}); await h.drain();
  const accepted = h.calls.filter(call => call.accepted).map(call => call.track);
  assert.ok(accepted.some(track => track.vss_id && !track.translationLanguage));            // out of the translation
  assert.ok(accepted.some(track => track.translationLanguage?.languageCode === 'ko'));       // then into Korean
  assert.ok(captions(h).some(message => message.lang === 'ko' && message.translated));
  assert.deepEqual(h.track, {languageCode:'en', translationLanguage:{languageCode:'ja'}}); // user's own state back
});

test('a refused caption request (429) captures nothing and restores the player', async () => {
  const h = harness({ccOn:false, refuseTranslations:true});
  // Checks the outcome (nothing captured, player restored); the early stop itself is visible in the
  // bridge debug log during the real-YouTube run ("refused x-ko 429").
  h.send('selectCaptions', {videoId:VIDEO, trackId:'x-ko'}); await h.drain();
  assert.ok(!captions(h).some(message => message.translated));
  assert.equal(h.ccOn, false);                           // CC turned back off
  assert.deepEqual(h.track, {languageCode:'en'});
});
