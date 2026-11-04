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
