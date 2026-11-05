import test from 'node:test';
import assert from 'node:assert/strict';
import '../parsers.js';
const {parseJSON3, normalizeCues, parseLRC, parseTimedLyrics} = globalThis.NPParsers;

test('JSON3 converts milliseconds, joins segments and preserves line breaks', () => {
  assert.deepEqual(parseJSON3({events:[{tStartMs:1000,dDurationMs:2500,segs:[{utf8:'Hello '},{utf8:'world\nagain'}]},
    {tStartMs:4000,segs:[{utf8:'Next'}]}, {tStartMs:0,wpWinPosId:1}]}),
  [{s:1,e:3.5,text:'Hello world\nagain'},{s:4,text:'Next'}]);
});
test('JSON3 malformed payload and blank control events yield no cues', () => {
  assert.deepEqual(parseJSON3('not JSON'), []);
  assert.deepEqual(parseJSON3({events:{not:'an array'}}), []);
  assert.deepEqual(parseJSON3({events:[null, {tStartMs:0,segs:[null]}]}), []);
  assert.deepEqual(normalizeCues([null,undefined,0]), []);
  assert.deepEqual(parseJSON3({events:[{tStartMs:0,segs:[{utf8:'\n'}]}, {segs:[{utf8:'missing time'}]}]}), []);
});
test('JSON3 aAppend combines incremental text instead of emitting duplicates', () => {
  assert.deepEqual(parseJSON3({events:[{tStartMs:0,dDurationMs:1000,segs:[{utf8:'Hello'}]},
    {tStartMs:500,dDurationMs:1000,aAppend:1,segs:[{utf8:' world'}]}]}, true),
  [{s:0,e:1.5,text:'Hello world'}]);
});
test('ASR cumulative rolling windows merge, suffix-prefix overlap is removed', () => {
  assert.deepEqual(normalizeCues([{s:0,e:2,text:'one'},{s:0.5,e:3,text:'one two'},
    {s:2,e:4,text:'two three'},{s:5,e:6,text:'three'}],true),
  [{s:0,e:2,text:'one two'},{s:2,e:4,text:'three'},{s:5,e:6,text:'three'}]);
});
test('normalization sorts, removes invalid rows, merges duplicates and clips overlaps', () => {
  assert.deepEqual(normalizeCues([{s:3,e:5,text:' B '},{s:0,e:4,text:'A'},{s:-1,text:'bad'},
    {s:NaN,text:'bad'},{s:4,e:6,text:'B'},{s:9,text:' '}]),
  [{s:0,e:3,text:'A'},{s:3,e:6,text:'B'}]);
});
test('LRC multiple timestamps, fractions, metadata, CRLF and final duration', () => {
  assert.deepEqual(parseLRC('[ar:Artist]\r\n[00:01.25][00:03.500]Hi\r\n[00:05]Bye',8),
    [{s:1.25,e:3.5,text:'Hi'},{s:3.5,e:5,text:'Hi'},{s:5,e:8,text:'Bye'}]);
});
test('LRC applies millisecond offset, clamps negatives, ignores malformed timestamps', () => {
  assert.deepEqual(parseLRC('[offset:-500]\n[00:00.20]First\n[00:70]bad\n[00:02:5]Second',5),
    [{s:0,e:2,text:'First'},{s:2,e:5,text:'Second'}]);
  assert.deepEqual(parseLRC('plain lyrics without timestamps'), []);
});
test('mobile timedLyrics nested renderer converts string millisecond values', () => {
  assert.deepEqual(parseTimedLyrics({contents:{timedLyricsRenderer:{timedLyricsData:[
    {lyricLine:'A',cueRange:{startTimeMilliseconds:'1200',endTimeMilliseconds:'2400'}},
    {lyricLine:'no timing'}]}}}), [{s:1.2,e:2.4,text:'A'}]);
  assert.deepEqual(parseTimedLyrics({lyrics:'unsynced'}), []);
});
test('ASR word stream is regrouped into sentences instead of YouTube rolling windows', () => {
  const words = (start, list) => ({tStartMs:start, dDurationMs:9000, wWinId:1,
    segs:list.map(([text, off]) => off === undefined ? {utf8:text} : {utf8:text, tOffsetMs:off})});
  const json = {events:[
    {tStartMs:0, dDurationMs:60000},                                  // window header
    words(1000, [['오늘은',], [' 날씨가', 300], [' 좋네요.', 700], [' 그런데', 1500]]),
    {tStartMs:3000, dDurationMs:500, wWinId:1, aAppend:1, segs:[{utf8:'\n'}]},
    words(3010, [[' 비가', ], [' 온대요', 400]]),                          // continues the sentence across the window
    words(9000, [['Next', ], [' one', 200]]),                          // > 4 s pause: new line
  ]};
  const cues = parseJSON3(json, true);
  assert.deepEqual(cues.map(c => c.text), ['오늘은 날씨가 좋네요.', '그런데 비가 온대요', 'Next one']);
  assert.equal(cues[0].s, 1); assert.equal(cues[1].s, 2.5);
  assert.ok(cues.every((c, i) => !cues[i + 1] || (c.e ?? c.s) <= cues[i + 1].s));
});
test('ASR lines split when they get long and keep short fragments joined over short pauses', () => {
  const segs = Array.from({length: 30}, (_, i) => ({utf8: '가', tOffsetMs: i * 100}));
  const long = parseJSON3({events:[{tStartMs:0, dDurationMs:5000, segs}]}, true);
  assert.equal(long.length, 2);
  assert.equal(long[0].text.length, 26);
  const frag = parseJSON3({events:[{tStartMs:0, dDurationMs:9000, segs:[{utf8:'知る'}, {utf8:'戻れないよ', tOffsetMs:2000}]}]}, true);
  assert.deepEqual(frag.map(c => c.text), ['知る戻れないよ']);
});
test('ASR regroup keeps textual appends, drops repeated windows, and never yields equal starts', () => {
  const appended = parseJSON3({events:[
    {tStartMs:0, dDurationMs:3000, segs:[{utf8:'Hello', tOffsetMs:0}]},
    {tStartMs:500, dDurationMs:2500, aAppend:1, segs:[{utf8:' world.'}]},
  ]}, true);
  assert.deepEqual(appended.map(c => c.text), ['Hello world.']);
  const repeated = parseJSON3({events:[
    {tStartMs:0, dDurationMs:3000, segs:[{utf8:'Hello', tOffsetMs:0}, {utf8:' world.', tOffsetMs:400}]},
    {tStartMs:0, dDurationMs:3000, segs:[{utf8:'Hello', tOffsetMs:0}, {utf8:' world.', tOffsetMs:400}]},
  ]}, true);
  assert.deepEqual(repeated.map(c => c.text), ['Hello world.']);
  const untimed = parseJSON3({events:[{tStartMs:0, dDurationMs:6000, segs:[
    {utf8:'First sentence.', tOffsetMs:0}, {utf8:' Second sentence.'}, {utf8:' Third sentence.'}]}]}, true);
  assert.equal(new Set(untimed.map(c => c.s)).size, untimed.length);
  assert.ok(untimed.map(c => c.text).join(' ').includes('Second sentence.'));
});
