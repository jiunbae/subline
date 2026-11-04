import test from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import {readFileSync} from 'node:fs';
import {createHash} from 'node:crypto';
const root = new URL('../', import.meta.url);
const source = file => readFileSync(new URL(file,root),'utf8');
const plain = value => JSON.parse(JSON.stringify(value));
const flush = async () => { for (let i=0;i<8;i++) await Promise.resolve(); };
function harness() {
  const listener = () => ({callbacks:[],addListener(fn) { this.callbacks.push(fn); }});
  const messages=[], sent=[], ports=[], timers=[], fetches=[];
  const tab={id:7,url:'https://www.youtube.com/watch?v=dQw4w9WgXcQ'};
  const runtime={id:'extension-id',lastError:null,onMessage:listener(),getManifest:()=>({version:'0.1.0'}),
    connectNative: name => {
      assert.equal(name,'com.nowplaying.host');
      const p={onDisconnect:listener(),onMessage:listener(),postMessage:m=>messages.push(plain(m)),disconnect() {}};
      ports.push(p); return p;
    }};
  const tabs={onRemoved:listener(),onUpdated:listener(),query:async()=>[tab],get:async()=>tab,
    sendMessage:async(id,m)=>sent.push({id,...plain(m)})};
  let fetchCount=0;
  const alarms={onAlarm:listener(),create:async()=>{},clear:async()=>{}};
  const context = vm.createContext({chrome:{runtime,tabs,alarms,action:{onClicked:listener()}},navigator:{userAgent:'Node'},
    console,URL,URLSearchParams,AbortSignal,Date,clearTimeout:()=>{},setTimeout:(fn,delay)=>{timers.push({fn,delay});return timers.length;},
    fetch:async(url, options)=>{fetchCount++;fetches.push({url,options});return {ok:true,json:async()=>({duration:100,syncedLyrics:'[00:01]hello'})};}});
  context.importScripts= file=>vm.runInContext(source(file),context);
  vm.runInContext(source('service-worker.js'),context);
  const publish = message => runtime.onMessage.callbacks[0]({op:'publish',message},
    {id:runtime.id,frameId:0,url:tab.url,tab},()=>{});
  return {runtime,tabs,alarms,tab,messages,sent,ports,timers,publish,fetches,fetchCount:()=>fetchCount};
}
const track={type:'track',site:'yt',videoId:'dQw4w9WgXcQ',title:'Example',artist:'Artist',duration:100,artwork:[],isAd:false};
test('manifest public key derives the pinned ID and both worlds attach at document_start',()=>{
  const manifest=JSON.parse(source('manifest.json'));
  const hash=createHash('sha256').update(Buffer.from(manifest.key,'base64')).digest('hex').slice(0,32);
  const id=[...hash].map(c=>String.fromCharCode(97+parseInt(c,16))).join('');
  assert.equal(id,'npkfiaebcfackgbinodgjobdlmeceaij');
  assert.deepEqual(manifest.content_scripts.map(s=>s.world),['MAIN','ISOLATED']);
  assert.ok(manifest.content_scripts.every(s=>s.run_at==='document_start'));
});
test('native reconnect sends hello and cached complete snapshot with increasing sequence',async()=>{
  const h=harness(); await flush();
  h.publish(track);
  h.publish({type:'clock',videoId:track.videoId,t:1,rate:1,paused:false,buffering:false});
  h.publish({type:'cues',videoId:track.videoId,source:'yt-captions',kind:'manual',synced:true,cues:[{s:1,e:2,text:'Hi'}]});
  h.ports[0].onDisconnect.callbacks[0]();
  assert.equal(h.timers[0].delay,1000);
  h.timers[0].fn(); await flush();
  assert.deepEqual(h.messages.slice(-4).map(m=>m.type),['hello','track','clock','cues']);
  const seqs=h.messages.filter(m=>m.tabId===7).map(m=>m.seq);
  assert.ok(seqs.every((s,i)=>!i||s>seqs[i-1]));
  assert.ok(h.messages.every(m=>m.v===1));
  h.ports[1].onDisconnect.callbacks[0]();
  assert.equal(h.timers[1].delay,2000);
});
test('worker rejects stale video clocks, unsafe artwork and untrusted senders',()=>{
  const h=harness(); h.publish({...track,artwork:[{url:'javascript:alert(1)',w:1,h:1}]});
  assert.deepEqual(h.messages.at(-1).artwork,[]);
  const count=h.messages.length;
  h.publish({type:'clock',videoId:'aaaaaaaaaaa',t:1,rate:1});
  h.runtime.onMessage.callbacks[0]({op:'publish',message:track},{id:'other',frameId:0,tab:h.tab,url:h.tab.url},()=>{});
  assert.equal(h.messages.length,count);
});
test('alarm wakes reconnection when a disconnected worker timer would be lost',()=>{
  const h=harness();h.ports[0].onDisconnect.callbacks[0]();
  h.alarms.onAlarm.callbacks[0]({name:'nowplaying-native-reconnect'});
  assert.equal(h.ports.length,2);
});
test('ads suppress cues and tab removal emits gone',()=>{
  const h=harness();h.publish({...track,isAd:true}); const count=h.messages.length;
  h.publish({type:'cues',videoId:track.videoId,source:'yt-captions',kind:'manual',synced:true,cues:[{s:1,text:'Ad'}]});
  assert.equal(h.messages.length,count);
  h.tabs.onRemoved.callbacks[0](7);
  assert.equal(h.messages.at(-1).type,'gone');
});
test('full navigation to a non-watch YouTube URL removes the previous track',()=>{
  const h=harness();h.publish(track);
  h.tabs.onUpdated.callbacks[0](7,{url:'https://www.youtube.com/feed/subscriptions'});
  assert.equal(h.messages.at(-1).type,'gone');
});
test('native visibility and validated commands route to content script',async()=>{
  const h=harness();await flush();h.sent.length=0;
  h.ports[0].onMessage.callbacks[0]({v:1,type:'visibility',visible:false});
  h.ports[0].onMessage.callbacks[0]({v:1,type:'cmd',tabId:7,action:'seek',t:30});
  h.ports[0].onMessage.callbacks[0]({v:1,type:'cmd',tabId:7,action:'seek',t:'invalid'});
  await flush();
  assert.deepEqual(h.sent.map(m=>m.type).sort(),['cmd','visibility']);
  assert.equal(h.sent.find(m=>m.type==='cmd').t,30);
});
test('LRCLIB fetch occurs in worker with omitted credentials and caches normalized cues',async()=>{
  const h=harness();
  const request={op:'lyrics',query:{title:'Example',artist:'Artist',album:'Album',duration:100}};
  const sender={id:h.runtime.id,frameId:0,url:'https://music.youtube.com/watch?v=dQw4w9WgXcQ',tab:h.tab};
  const run=()=>new Promise(resolve=>h.runtime.onMessage.callbacks[0](request,sender,resolve));
  assert.deepEqual(plain(await run()),{cues:[{s:1,e:100,text:'hello'}]});
  await run(); assert.equal(h.fetchCount(),1);
  assert.equal(h.fetches[0].options.credentials,'omit');
  assert.equal(new URL(h.fetches[0].url).searchParams.get('artist_name'),'Artist');
  const mismatch={...request,query:{...request.query,duration:110}};
  const result=await new Promise(resolve=>h.runtime.onMessage.callbacks[0](mismatch,sender,resolve));
  assert.deepEqual(plain(result),{cues:[]});
});
test('LRCLIB retries once with localized/decorative suffixes removed',async()=>{
  const h=harness();
  const request={op:'lyrics',query:{title:'Song (Official Audio)',artist:'The Band(더 밴드) - Topic',duration:110}};
  const sender={id:h.runtime.id,frameId:0,url:'https://music.youtube.com/watch?v=dQw4w9WgXcQ',tab:h.tab};
  const result=await new Promise(resolve=>h.runtime.onMessage.callbacks[0](request,sender,resolve));
  assert.deepEqual(plain(result),{cues:[]}); // duration mismatch on both attempts
  const q=h.fetches.map(f=>new URL(f.url).searchParams);
  assert.equal(q.length,2);
  assert.equal(q[1].get('track_name'),'Song');
  assert.equal(q[1].get('artist_name'),'The Band');
});
