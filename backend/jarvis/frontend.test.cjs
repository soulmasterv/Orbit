const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const vm=require('node:vm');
const source=fs.readFileSync(__dirname+'/public/app.js','utf8').replace(/^import[^\n]+\n/,'');
const flush=()=>new Promise(resolve=>setImmediate(resolve));
function deferred(){let resolve;const promise=new Promise(r=>resolve=r);return {promise,resolve};}
async function fixture(){
  const elements=Object.fromEntries(['status','start','stop','controls','login','password','logout','memory-panel'].map(id=>[id,{disabled:false,hidden:false,value:''}]));
  const listeners={},docListeners={},sockets=[],contexts=[],streams=[];
  let media=()=>Promise.resolve(makeStream());let worklet=()=>Promise.resolve();
  function makeStream(){const track={stopped:false,stop(){this.stopped=true;}};const stream={track,getTracks:()=>[track]};streams.push(stream);return stream;}
  class Context {
    state='running';currentTime=0;closed=false;sources=[];audioWorklet={addModule:()=>worklet()};
    constructor(){contexts.push(this);}
    resume(){return Promise.resolve();}close(){this.closed=true;return Promise.resolve();}
    createMediaStreamSource(){return {connect(){},disconnect(){}};}
    createBufferSource(){const node={connect(){},start(){},stop(){this.stopped=true;}};this.sources.push(node);return node;}
    createBuffer(_,size){return {getChannelData:()=>new Float32Array(size),duration:size/24000};}
  }
  class Socket {
    readyState=1;bufferedAmount=0;sent=[];closed=false;
    constructor(){sockets.push(this);}send(data){this.sent.push(data);}close(){this.closed=true;}
  }
  const window={isSecureContext:true,AudioWorkletNode:class {},addEventListener:(name,fn)=>{(listeners[name]??=[]).push(fn);},dispatchEvent:e=>{for(const fn of listeners[e.type]??[])fn();}};
  const document={hidden:false,getElementById:id=>elements[id],addEventListener:(name,fn)=>{docListeners[name]=fn;}};
  let fetchImpl=async path=>({ok:true,status:200,json:async()=>({csrf:'fixture-only-token'})});
  const context={window,document,navigator:{mediaDevices:{getUserMedia:()=>media()}},AudioContext:Context,
    AudioWorkletNode:class {port={};connect(){}disconnect(){}},WebSocket:Socket,
    location:{origin:'https://jarvis.labbing.space'},Event:class {constructor(type){this.type=type;}},
    initMemory(){},showMemory:async()=>{},proposeMemory(){},fetch:(...args)=>fetchImpl(...args),atob:s=>Buffer.from(s,'base64').toString('binary')};
  vm.runInNewContext(source,context);await flush();
  return {window,document,elements,sockets,contexts,streams,makeStream,docListeners,
    setMedia:fn=>media=fn,setWorklet:fn=>worklet=fn,setFetch:fn=>fetchImpl=fn,
    start:()=>elements.start.onclick({isTrusted:true}),event:name=>window.dispatchEvent({type:name})};
}
test('narrow lifecycle hook exposes no credentials and idle never opens microphone',async()=>{
  const f=await fixture();assert.equal(f.window.orbitJarvis.version,1);
  assert.deepEqual(Object.keys(f.window.orbitJarvis.snapshot()).sort(),['authenticated','memoryAvailable','phase']);
  assert.equal(f.sockets.length,0);assert.equal(f.streams.length,0);
});
test('Stop during pending microphone acquisition disposes late stream without opening socket',async()=>{
  const f=await fixture(),pending=deferred();f.setMedia(()=>pending.promise);
  const start=f.start();await flush();f.window.orbitJarvis.stop();const stream=f.makeStream();pending.resolve(stream);await start;
  assert.equal(stream.track.stopped,true);assert.equal(f.contexts[0].closed,true);assert.equal(f.sockets.length,0);
});
test('Stop during worklet setup followed by restart cannot invalidate new session',async()=>{
  const f=await fixture(),pending=deferred();f.setWorklet(()=>pending.promise);
  const old=f.start();await flush();f.window.orbitJarvis.stop();f.setWorklet(()=>Promise.resolve());await f.start();
  const socket=f.sockets[0];pending.resolve();await old;
  assert.equal(f.sockets.length,1);assert.equal(socket.closed,false);assert.equal(f.streams[0].track.stopped,true);
  f.window.orbitJarvis.stop();assert.equal(socket.closed,true);assert.equal(f.streams[1].track.stopped,true);
});
test('stale socket events cannot stop replacement session or replay audio',async()=>{
  const f=await fixture();await f.start();const old=f.sockets[0];f.window.orbitJarvis.stop();await f.start();
  old.onclose();old.onerror();old.onmessage({data:JSON.stringify({type:'ready'})});
  assert.equal(f.sockets[1].closed,false);assert.equal(f.contexts[1].closed,false);
});
test('background, network loss, memory change and session end stop all resources without redial',async()=>{
  for(const event of ['pagehide','offline','orbit-jarvis-memory-changed','orbit-jarvis-auth-expired','hidden','ended']){
    const f=await fixture();await f.start();const socket=f.sockets[0];socket.onmessage({data:'{"type":"ready"}'});
    if(event==='hidden'){f.document.hidden=true;f.docListeners.visibilitychange();}
    else if(event==='ended')socket.onmessage({data:'{"type":"ended"}'});
    else f.event(event);
    await flush();assert.equal(socket.closed,true,event);assert.equal(f.streams[0].track.stopped,true,event);assert.equal(f.contexts[0].closed,true,event);
    assert.equal(f.sockets.length,1);assert.equal(f.window.orbitJarvis.snapshot().phase,'idle');
  }
});
test('denied microphone is clear and creates no socket',async()=>{
  const f=await fixture();f.setMedia(()=>Promise.reject({name:'NotAllowedError'}));await f.start();
  assert.match(f.elements.status.textContent,/Microphone denied/);assert.equal(f.sockets.length,0);assert.equal(f.contexts[0].closed,true);
});
test('sign out failure is not represented as successful sign out',async()=>{
  const f=await fixture();await f.start();f.setFetch(async()=>({ok:false,status:503}));await f.elements.logout.onclick();
  assert.equal(f.sockets[0].closed,true);assert.equal(f.window.orbitJarvis.snapshot().authenticated,true);assert.match(f.elements.status.textContent,/could not be confirmed/);
});
test('sign out makes exactly one mutation, stops capture and clears authenticated state',async()=>{
  const f=await fixture();await f.start();let count=0;
  f.setFetch(async(path,options)=>{assert.equal(path,'/logout');assert.equal(options.method,'POST');count++;return {ok:true,status:200};});
  await f.elements.logout.onclick();assert.equal(count,1);assert.equal(f.streams[0].track.stopped,true);assert.equal(f.window.orbitJarvis.snapshot().authenticated,false);
});
test('synthetic clicks and hidden pages cannot start capture',async()=>{
  const f=await fixture();await f.elements.start.onclick({isTrusted:false});f.document.hidden=true;await f.start();
  assert.equal(f.streams.length,0);assert.equal(f.sockets.length,0);
});
test('Stop halts queued reply playback as well as capture',async()=>{
  const f=await fixture();await f.start();const socket=f.sockets[0];
  socket.onmessage({data:'{"type":"ready"}'});socket.onmessage({data:'{"type":"audio","data":"AAA="}'});
  const node=f.contexts[0].sources[0];assert.ok(node);f.window.orbitJarvis.stop();
  assert.equal(node.stopped,true);assert.equal(f.contexts[0].closed,true);assert.equal(f.streams[0].track.stopped,true);
});
test('socket closure checks login expiry with GET only and does not reconnect',async()=>{
  const f=await fixture();await f.start();let requests=0;
  f.setFetch(async(path,options)=>{assert.equal(path,'/session');assert.equal(options,undefined);requests++;return {ok:false,status:401};});
  f.sockets[0].onclose();await flush();assert.equal(requests,1);assert.equal(f.sockets.length,1);
  assert.equal(f.window.orbitJarvis.snapshot().authenticated,false);assert.match(f.elements.status.textContent,/Session expired/);
});
