import {initMemory,showMemory,proposeMemory} from './memory.js';
const $=id=>document.getElementById(id);
let csrf=null, generation=0, session=null, authGeneration=0;
let state={authenticated:false,phase:'idle',memoryAvailable:!!$('memory-panel')};
function publish(phase,message){
  state={...state,phase};
  if(message)$('status').textContent=message;
  $('start').disabled=!state.authenticated||phase!=='idle';
  $('stop').disabled=phase==='idle';
  window.dispatchEvent(new Event('orbit-jarvis-state'));
}
function signed(value){
  state={...state,authenticated:value};
  $('login').hidden=value;$('controls').hidden=!value;
  void showMemory(value);publish('idle');
}
function dispose(s){
  if(!s)return;
  s.ws?.close();s.stream?.getTracks().forEach(t=>t.stop());
  try{s.capture?.disconnect();s.source?.disconnect();}catch{}
  for(const node of s.playing){try{node.stop();}catch{}}
  s.playing.clear();s.next=0;
  if(s.ctx)void s.ctx.close().catch(()=>{});
}
function stop(message='Stopped. Microphone released.'){
  generation++;const old=session;session=null;dispose(old);publish('idle',message);
}
function current(s){return session===s&&s.id===generation;}
function fail(s,message){if(current(s))stop(message);else dispose(s);}
window.orbitJarvis=Object.freeze({version:1,stop,snapshot:()=>({...state})});
initMemory(()=>csrf);
$('login').onsubmit=async e=>{
  e.preventDefault();const attempt=++authGeneration;
  try{
    const r=await fetch('/login',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({password:$('password').value})});
    $('password').value='';
    if(attempt!==authGeneration)return;
    if(!r.ok)throw Error('Sign in failed. Wait a minute before retrying.');
    csrf=(await r.json()).csrf;if(attempt!==authGeneration)return;
    signed(true);publish('idle','Ready. Press Start voice.');
  }catch{if(attempt===authGeneration)publish('idle','Sign in failed. Check your connection and try again.');}
};
$('start').onclick=async e=>{
  // Real user gesture preserves iOS audio activation. No automatic redial.
  if(!e.isTrusted||session||!state.authenticated||document.hidden)return;
  const s={id:++generation,ctx:null,stream:null,ws:null,playing:new Set(),next:0};
  session=s;publish('starting','Requesting microphone…');
  try{
    if(!window.isSecureContext||!navigator.mediaDevices||!window.AudioWorkletNode)throw Error('Voice needs a supported browser with trusted HTTPS.');
    s.ctx=new AudioContext();
    s.ctx.onstatechange=()=>{if(current(s)&&['interrupted','suspended'].includes(s.ctx.state)&&state.phase==='listening')stop('Audio interrupted. Tap Start voice when ready.');};
    await s.ctx.resume();if(!current(s)){dispose(s);return;}
    const stream=await navigator.mediaDevices.getUserMedia({audio:{channelCount:1,echoCancellation:true,noiseSuppression:true},video:false});
    s.stream=stream;if(!current(s)||document.hidden){dispose(s);return;}
    for(const track of stream.getTracks()){
      track.onended=()=>fail(s,'Microphone disconnected. Tap Start voice when ready.');
      track.onmute=()=>fail(s,'Microphone interrupted. Tap Start voice when ready.');
    }
    await s.ctx.audioWorklet.addModule('/capture.js');
    if(!current(s)||document.hidden){dispose(s);return;}
    const socket=new WebSocket(location.origin.replace(/^http/,'ws')+'/voice');s.ws=socket;
    socket.onopen=()=>{if(!current(s)){socket.close();return;}socket.send(JSON.stringify({csrf}));publish('starting','Connecting to JARVIS…');};
    socket.onmessage=e=>{
      if(!current(s))return;
      try{
        const msg=JSON.parse(e.data);
        if(msg.type==='memory_proposal')proposeMemory(msg.text);
        if(msg.type==='ready'&&state.phase!=='listening'){
          s.source=s.ctx.createMediaStreamSource(s.stream);s.capture=new AudioWorkletNode(s.ctx,'capture');
          s.capture.port.onmessage=e=>{
            if(!current(s))return;
            if(socket.readyState===1){if(socket.bufferedAmount>65536){stop('Connection too slow. Tap Start voice to try again.');return;}socket.send(e.data);}
          };
          s.source.connect(s.capture);s.capture.connect(s.ctx.destination);publish('listening','Listening. Speak naturally; pause for a reply.');
        }
        if(msg.type==='interrupted'){for(const n of s.playing){try{n.stop();}catch{}}s.playing.clear();s.next=0;}
        if(msg.type==='audio'&&s.ctx){
          const raw=atob(msg.data);if(raw.length%2)throw Error();
          const view=new DataView(new ArrayBuffer(raw.length));for(let i=0;i<raw.length;i++)view.setUint8(i,raw.charCodeAt(i));
          const buffer=s.ctx.createBuffer(1,raw.length/2,24000),channel=buffer.getChannelData(0);
          for(let i=0;i<channel.length;i++)channel[i]=view.getInt16(i*2,true)/32768;
          if(s.next-s.ctx.currentTime>10){stop('Speaker queue full. Start a new conversation.');return;}
          const node=s.ctx.createBufferSource();node.buffer=buffer;node.connect(s.ctx.destination);s.playing.add(node);
          node.onended=()=>s.playing.delete(node);s.next=Math.max(s.next,s.ctx.currentTime+.02);node.start(s.next);s.next+=buffer.duration;
        }
        if(msg.type==='ended')stop('Session ended. Check login or session limits, then start a new conversation.');
      }catch{fail(s,'Audio connection failed. Start a new conversation.');}
    };
    socket.onerror=()=>fail(s,'Connection refused. Check login, shared limits, and server status.');
    socket.onclose=()=>fail(s,'Disconnected. Check your session, then tap Start voice.');
  }catch(e){
    fail(s,e.name==='NotAllowedError'?'Microphone denied. Allow access in Settings, then tap Start voice.':'Voice could not start. Check microphone, network, and audio support.');
  }
};
$('stop').onclick=()=>stop();
$('logout').onclick=async()=>{
  stop();const attempt=++authGeneration;
  try{
    const r=await fetch('/logout',{method:'POST',headers:{'X-CSRF-Token':csrf}});
    if(attempt!==authGeneration)return;
    if(!r.ok&&r.status!==401)throw Error();
    csrf=null;signed(false);publish('idle','Signed out.');
  }catch{publish('idle','Sign out could not be confirmed. Check your connection and try again.');}
};
window.addEventListener('pagehide',()=>stop('Paused. Tap Start voice when ready.'));
document.addEventListener('visibilitychange',()=>{if(document.hidden)stop('Paused in background. Tap Start voice when ready.');});
window.addEventListener('offline',()=>stop('Network disconnected. Tap Start voice after reconnecting.'));
window.addEventListener('orbit-jarvis-memory-changed',()=>stop('Memory updated. Start a new conversation to use it.'));
window.addEventListener('orbit-jarvis-auth-expired',()=>{stop();csrf=null;signed(false);publish('idle','Session expired. Sign in again.');});
const initialAuth=authGeneration;
fetch('/session').then(async r=>{
  if(initialAuth!==authGeneration)return;
  if(r.ok){const data=await r.json();if(initialAuth!==authGeneration)return;csrf=data.csrf;signed(true);publish('idle','Ready. Press Start voice.');}
  else if(r.status===401){signed(false);publish('idle','Sign in to begin.');}
}).catch(()=>publish('idle','Server unavailable. Reload when connected.'));
publish('idle');
