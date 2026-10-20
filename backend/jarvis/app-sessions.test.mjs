import {test} from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import {appSessionHandler} from './app-sessions.mjs';

async function fixture(t){
  const sessions=new Map(),clients=new Map(),pool={active:new Set(),limits:{concurrent:1}};
  let now=Date.now();
  const server=http.createServer(appSessionHandler({secret:'a'.repeat(64),origin:'https://jarvis.labbing.space',sessions,clients,pool,now:()=>now}));
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
  t.after(()=>{server.closeAllConnections();server.close();});
  const url=`http://127.0.0.1:${server.address().port}/session`;
  let nonce=0;
  const body=()=>({version:1,installation_id:'12345678-1234-1234-1234-123456789abc',nonce:String(++nonce).padStart(24,'n')});
  const call=(method='POST',value=body(),auth=true)=>fetch(url,{method,headers:{'Content-Type':'application/json',...(auth?{Authorization:'Bearer '+'a'.repeat(64)}:{})},body:JSON.stringify(value)});
  return {sessions,clients,pool,body,call,advance:ms=>now+=ms};
}
test('private issuer rejects missing authentication before parsing',async t=>{
  const f=await fixture(t),r=await f.call('POST',{},false);assert.equal(r.status,401);assert.equal(f.sessions.size,0);
});
test('native device gets bounded session and strict host-only contract',async t=>{
  const f=await fixture(t),r=await f.call(),b=await r.json();assert.equal(r.status,200);assert.equal(r.headers.get('cache-control'),'no-store');
  assert.equal(b.cookie.domain,'jarvis.labbing.space');assert.equal(b.cookie.path,'/');assert.equal(b.cookie.same_site,'Strict');
  assert.ok(b.cookie.secure&&b.cookie.http_only);assert.ok(b.expires_at<=Date.now()/1000+900);assert.equal(f.sessions.size,1);
});
test('revocation isolates device and closes its socket, preserving ordinary web sessions',async t=>{
  const f=await fixture(t),r=await f.call(),b=await r.json();let closed=0;
  f.sessions.set('ordinary-web',{expires:Date.now()+100000});f.clients.set(b.cookie.value,{close:()=>closed++});
  const revoked=await f.call('DELETE');assert.equal(revoked.status,200);assert.equal((await revoked.json()).revoked,true);
  assert.equal(closed,1);assert.equal(f.sessions.size,1);assert.ok(f.sessions.has('ordinary-web'));
});
test('replays and malformed requests do not create sessions',async t=>{
  const f=await fixture(t),b=f.body();assert.equal((await f.call('POST',b)).status,200);assert.equal((await f.call('POST',b)).status,409);
  assert.equal((await f.call('POST',{...f.body(),installation_id:'app-flag'})).status,400);
  assert.equal((await f.call('POST',{...f.body(),nonce:'bad'})).status,400);assert.equal(f.sessions.size,1);
});
test('shared voice concurrency and issuance rate cap are enforced',async t=>{
  const f=await fixture(t);f.pool.active.add('existing-call');assert.equal((await f.call()).status,409);f.pool.active.clear();
  for(let i=0;i<11;i++)assert.equal((await f.call()).status,200);
  assert.equal((await f.call()).status,429);assert.equal(f.sessions.size,1);
});
