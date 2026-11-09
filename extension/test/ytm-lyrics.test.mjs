import test from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import {readFileSync} from 'node:fs';

const root = new URL('../', import.meta.url);
const source = file => readFileSync(new URL(file, root), 'utf8');
const plain = value => JSON.parse(JSON.stringify(value));
const CHANNEL = 'subline-v1';
const flush = async () => { for (let i = 0; i < 30; i++) await Promise.resolve(); };

// The shapes YouTube Music returned in 2026-11: next carries the Lyrics tab's browseId; the web
// client's browse answer is a description shelf (untimed). Timed data is the mobile shape.
const nextResponse = {contents:{singleColumnMusicWatchNextResultsRenderer:{tabbedRenderer:{watchNextTabbedResultsRenderer:{tabs:[
  {tabRenderer:{title:'Up next'}},
  {tabRenderer:{title:'Lyrics', endpoint:{browseEndpoint:{browseId:'MPLYt_abc'}}}},
]}}}}};
const plainBrowse = {contents:{sectionListRenderer:{contents:[{musicDescriptionShelfRenderer:{
  description:{runs:[{text:'First line\nSecond line\n\nThird line\n'}]}, footer:{runs:[{text:'Source: LyricFind'}]}}}]}}};
const timedBrowse = {contents:{elementRenderer:{newElement:{type:{componentType:{model:{timedLyricsModel:{lyricsData:{timedLyricsData:[
  {lyricLine:'Later line', cueRange:{startTimeMilliseconds:'5000', endTimeMilliseconds:'8000'}},
  {lyricLine:'Opening line', cueRange:{startTimeMilliseconds:'1500', endTimeMilliseconds:'5000'}},
]}}}}}}}}};

function harness({browse = plainBrowse, next = nextResponse, withNetworkManager = true} = {}) {
  const posted = [], calls = [], listeners = [];
  const location = new URL('https://music.youtube.com/watch?v=song1234567');
  const networkManager = {fetch: async (path, body) => {
    calls.push({path, body: plain(body)});
    return plain(path.startsWith('/next') ? next : browse);
  }};
  const window = {
    addEventListener(type, fn) { if (type === 'message') listeners.push(fn); },
    postMessage(data) {
      if (data.direction === 'from-main') posted.push(plain(data));
      for (const fn of listeners) fn({data, source: window, origin: location.origin});
    },
    fetch: async () => { throw new Error('plain fetch not expected'); },
  };
  const context = vm.createContext({
    window, location, URL, URLSearchParams, XMLHttpRequest: class { open() {} send() {} },
    document: {querySelector: s => s === 'ytmusic-app' && withNetworkManager ? {networkManager} : null},
    setTimeout, clearTimeout,
  });
  for (const file of ['parsers.js', 'bridge.js']) vm.runInContext(source(file), context, {filename: file});
  return {
    posted, calls, location,
    ask: id => window.postMessage({channel: CHANNEL, direction: 'to-main', kind: 'lyrics', videoId: id}),
    lyrics: () => posted.filter(m => m.kind === 'lyrics'),
  };
}

test('YTM lyrics: untimed description shelf becomes unsynced lines through the page network manager', async () => {
  const h = harness();
  h.ask('song1234567'); await flush();
  assert.deepEqual(h.calls.map(c => c.path), ['/next?prettyPrint=false', '/browse?prettyPrint=false']);
  assert.deepEqual(h.calls[1].body, {browseId: 'MPLYt_abc'});
  const [m] = h.lyrics();
  assert.equal(m.synced, false);
  assert.deepEqual(m.cues.map(c => c.text), ['First line', 'Second line', '', 'Third line']);
});

test('YTM lyrics: timed data wins and is sorted, in seconds', async () => {
  const h = harness({browse: timedBrowse});
  h.ask('song1234567'); await flush();
  const [m] = h.lyrics();
  assert.equal(m.synced, true);
  assert.deepEqual(m.cues, [{s: 1.5, e: 5, text: 'Opening line'}, {s: 5, e: 8, text: 'Later line'}]);
});

test('YTM lyrics: no Lyrics tab posts an empty result (the placeholder stands); results are reused', async () => {
  const h = harness({next: {contents: {}}});
  h.ask('song1234567'); await flush();
  assert.deepEqual(h.lyrics()[0].cues, []);
  h.ask('song1234567'); await flush();
  assert.equal(h.calls.length, 1); // cached per video
});

test('YTM lyrics: an answer for a song already left is not posted; invalid ids are ignored', async () => {
  const h = harness();
  h.ask('../evil'); await flush();
  assert.equal(h.calls.length, 0);
  h.ask('song1234567');
  h.location.searchParams.set('v', 'other123456');
  await flush();
  assert.equal(h.lyrics().length, 0);
});
