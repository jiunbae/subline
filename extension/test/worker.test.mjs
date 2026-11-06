import test from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import {readFileSync} from 'node:fs';
import {createHash} from 'node:crypto';
const root = new URL('../', import.meta.url);
const source = file => readFileSync(new URL(file,root),'utf8');
const plain = value => JSON.parse(JSON.stringify(value));
const flush = async () => { for (let i=0;i<8;i++) await Promise.resolve(); };
function harness(fetchImpl) {
  const listener = () => ({callbacks:[],addListener(fn) { this.callbacks.push(fn); }});
  const messages=[], sent=[], ports=[], timers=[], fetches=[];
  const tab={id:7,url:'https://www.youtube.com/watch?v=dQw4w9WgXcQ'};
  const runtime={id:'extension-id',lastError:null,onMessage:listener(),getManifest:()=>({version:'0.1.0'}),
    connectNative: name => {
      assert.equal(name,'dev.jiun.subline.host');
      const p={onDisconnect:listener(),onMessage:listener(),postMessage:m=>messages.push(plain(m)),disconnect() {}};
      ports.push(p); return p;
    }};
  const tabs={onRemoved:listener(),onUpdated:listener(),query:async()=>[tab],get:async()=>tab,
    sendMessage:async(id,m)=>sent.push({id,...plain(m)})};
  let fetchCount=0;
  const alarms={onAlarm:listener(),create:async()=>{},clear:async()=>{}};
  const context = vm.createContext({chrome:{runtime,tabs,alarms,action:{onClicked:listener()}},navigator:{userAgent:'Node'},
    console,URL,URLSearchParams,AbortSignal,Date,clearTimeout:()=>{},setTimeout:(fn,delay)=>{timers.push({fn,delay});return timers.length;},
    fetch:async(url, options)=>{fetchCount++;fetches.push({url,options});
      return fetchImpl ? fetchImpl(url) : {ok:true,json:async()=>({duration:100,syncedLyrics:'[00:01]hello'})};}});
  context.importScripts= file=>vm.runInContext(source(file),context);
  vm.runInContext(source('service-worker.js'),context);
  const publish = message => runtime.onMessage.callbacks[0]({op:'publish',message},
    {id:runtime.id,frameId:0,url:tab.url,tab},()=>{});
  return {runtime,tabs,alarms,tab,messages,sent,ports,timers,publish,fetches,fetchCount:()=>fetchCount};
}
// The companion app answered once: external lyric lookups are allowed from then on.
const ready=h=>h.ports[0].onMessage.callbacks[0]({v:1,type:'visibility',visible:true});
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
  h.alarms.onAlarm.callbacks[0]({name:'subline-native-reconnect'});
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
test('caption track lists are sanitized, cached for snapshots, and selection commands validated',async()=>{
  const h=harness(); await flush(); h.publish(track);
  h.publish({type:'captionTracks',videoId:track.videoId,tracks:[
    {id:'en',lang:'en',name:'English'},{id:'ko:asr',lang:'ko',name:'Korean (auto)',kind:'asr'},
    {id:'bad id!',lang:'x',name:'nope'},{id:'ja',lang:'ja'}]});
  const sent=h.messages.at(-1);
  assert.equal(sent.type,'captionTracks');
  assert.deepEqual(sent.tracks,[{id:'en',lang:'en',name:'English'},{id:'ko:asr',lang:'ko',name:'Korean (auto)',kind:'asr'},{id:'ja',lang:'ja',name:'ja'}]);
  h.ports[0].onDisconnect.callbacks[0](); h.timers[0].fn(); await flush();
  assert.ok(h.messages.slice(-4).some(m=>m.type==='captionTracks'));
  h.sent.length=0;
  h.ports[1].onMessage.callbacks[0]({v:1,type:'selectCaptions',tabId:7,trackId:'en"><x'});
  h.ports[1].onMessage.callbacks[0]({v:1,type:'selectCaptions',tabId:7,trackId:'ko:asr'});
  await flush();
  assert.deepEqual(h.sent.filter(m=>m.type==='selectCaptions').map(m=>m.trackId),['ko:asr']);
});
test('secondary caption slot is forwarded, kept apart from main cues in snapshots, and can be cleared',async()=>{
  const h=harness(); await flush(); h.publish(track);
  h.publish({type:'cues',videoId:track.videoId,source:'yt-captions',lang:'en',kind:'manual',synced:true,cues:[{s:1,e:2,text:'Hello'}]});
  h.publish({type:'cues',videoId:track.videoId,source:'yt-captions',lang:'ko',kind:'manual',synced:true,slot:2,cues:[{s:1,e:2,text:'안녕'}]});
  assert.equal(h.messages.at(-1).slot,2);
  h.ports[0].onDisconnect.callbacks[0](); h.timers[0].fn(); await flush();
  const cues=h.messages.filter(m=>m.type==='cues').slice(-2);
  assert.deepEqual(cues.map(m=>m.slot ?? 1),[1,2]);
  h.sent.length=0;
  h.ports[1].onMessage.callbacks[0]({v:1,type:'selectCaptions',tabId:7,trackId:'',slot:2});
  h.ports[1].onMessage.callbacks[0]({v:1,type:'selectCaptions',tabId:7,trackId:'',slot:1});
  await flush();
  assert.deepEqual(h.sent.filter(m=>m.type==='selectCaptions').map(m=>[m.trackId,m.slot]),[['',2]]);
});
test('translation targets are forwarded only as x-<lang> translation entries; cue trackId is validated',async()=>{
  const h=harness(); await flush(); h.publish(track);
  h.publish({type:'captionTracks',videoId:track.videoId,tracks:[{id:'en',lang:'en',name:'English'}],
    translations:[{id:'x-ko',lang:'ko',name:'Korean',kind:'translation'},{id:'ko',lang:'ko',name:'spoof',kind:'translation'},{id:'x-ja',lang:'ja',name:'Japanese'}]});
  assert.deepEqual(h.messages.at(-1).translations,[{id:'x-ko',lang:'ko',name:'Korean',kind:'translation'}]);
  h.publish({type:'cues',videoId:track.videoId,source:'yt-captions',lang:'ko',kind:'manual',synced:true,slot:2,trackId:'x-ko',cues:[{s:1,e:2,text:'안녕'}]});
  assert.equal(h.messages.at(-1).trackId,'x-ko');
  h.publish({type:'cues',videoId:track.videoId,source:'yt-captions',lang:'ko',kind:'manual',synced:true,trackId:'bad id',cues:[{s:1,e:2,text:'x'}]});
  assert.equal(h.messages.at(-1).trackId,undefined);
});
test('incognito tabs are ignored and the extension never fetches anything itself',async()=>{
  const h=harness();
  const sender={id:h.runtime.id,frameId:0,url:'https://www.youtube.com/watch?v=dQw4w9WgXcQ',tab:{...h.tab,incognito:true}};
  const count=h.messages.length;
  h.runtime.onMessage.callbacks[0]({op:'publish',message:track},sender,()=>{});
  assert.equal(h.messages.length,count);
  assert.equal(JSON.parse(source('manifest.json')).incognito,'not_allowed');
  for (const f of ['bridge.js','content.js','adapters.js','parsers.js','service-worker.js'])
    assert.ok(!/\bfetch\(\s*[`'"]https?:/.test(source(f)), `${f} must not make its own network requests`);
});
test('reconnect replays tabs in playback-activation order (last started is replayed last)',async()=>{
  const h=harness(); await flush();
  const tabA={id:7,url:'https://www.youtube.com/watch?v=aaaaaaaaaaa'}, tabB={id:8,url:'https://www.youtube.com/watch?v=bbbbbbbbbbb'};
  h.tabs.query=async()=>[tabA,tabB];
  const pub=(tab,msg)=>h.runtime.onMessage.callbacks[0]({op:'publish',message:msg},{id:h.runtime.id,frameId:0,url:tab.url,tab},()=>{});
  const tr=v=>({...track,videoId:v}), clk=(v,paused)=>({type:'clock',videoId:v,t:1,rate:1,paused,buffering:false});
  pub(tabB,tr('bbbbbbbbbbb')); pub(tabA,tr('aaaaaaaaaaa'));
  pub(tabA,clk('aaaaaaaaaaa',false));            // A started first …
  await new Promise(r=>setTimeout(r,5));
  pub(tabB,clk('bbbbbbbbbbb',false));            // … then B: B is the one to follow
  h.ports[0].onDisconnect.callbacks[0](); h.timers[0].fn(); await flush();
  const clocks=h.messages.filter(m=>m.type==='clock').slice(-2).map(m=>m.tabId);
  assert.deepEqual(clocks,[7,8]);
});
test('least privilege: https-only hosts, no cookie or internal-API access in shipped scripts',()=>{
  const m=JSON.parse(source('manifest.json'));
  assert.deepEqual(m.permissions,['nativeMessaging','alarms']);
  assert.deepEqual(m.host_permissions,['https://www.youtube.com/*','https://music.youtube.com/*']); // lyrics are looked up by the app
  assert.ok([...m.host_permissions,...m.content_scripts.flatMap(c=>c.matches)].every(p=>p.startsWith('https://')));
  for (const f of ['bridge.js','content.js','adapters.js','parsers.js','service-worker.js']) {
    const s=source(f);
    assert.ok(!/document\.cookie|SAPISID|youtubei\/v1|Authorization/.test(s), `${f} must not touch cookies, auth headers or internal APIs`);
  }
  const h=harness(); const count=h.messages.length;
  h.runtime.onMessage.callbacks[0]({op:'publish',message:track},{id:h.runtime.id,frameId:0,url:'http://www.youtube.com/watch?v=dQw4w9WgXcQ',tab:h.tab},()=>{});
  assert.equal(h.messages.length,count); // plain-http pages are ignored
});
