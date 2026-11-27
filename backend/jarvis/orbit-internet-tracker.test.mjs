import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';import os from 'node:os';import path from 'node:path';import crypto from 'node:crypto';
import {OrbitInternetTracker,remaining} from './orbit-internet-tracker.mjs';
import http from 'node:http';
const PHONE='201000000002',OWNER='201000000001';
test('directory includes existing users, invited contacts and owner without jobs or writes',t=>{
 const f=fixture(t);f.line(1);f.line(2,'we');
 const s=f.requests.read();s.users[PHONE].name='Saved contact';s.users['201000000003']={lines:[{number:'0445678901',carrier:'we'}],providerConsent:'private fixture'};f.requests.save(s);
 const before=JSON.stringify(f.requests.read());
 const list=f.tracker.directory();assert.equal(list.version,1);assert.equal(list.contacts.length,3);
 const saved=list.contacts.find(c=>c.phone===PHONE);assert.equal(saved.name,'Saved contact');assert.equal(saved.lines.length,2);
 assert.equal(list.contacts.find(c=>c.phone==='201000000003').allowed,false);
 assert.ok(!JSON.stringify(list).includes('private fixture'));assert.equal(JSON.stringify(f.requests.read()),before);assert.equal(f.calls,0);
});
function fixture(t){
 const root=fs.mkdtempSync(path.join(os.tmpdir(),'orbit-tracker-'));t.after(()=>fs.rmSync(root,{recursive:true,force:true}));
 for(const d of ['internet-queued','internet-processing','internet-done','internet-results','internet-audio'])fs.mkdirSync(path.join(root,d));
 let state={version:1,friendsEnabled:true,invites:{[PHONE]:true},users:{[PHONE]:{lines:[]}}};let calls=0;
 const requests={root,owners:[OWNER],read:()=>structuredClone(state),save:s=>{state=structuredClone(s);},allowed:(p,s=state)=>p===OWNER||(s.friendsEnabled&&s.invites[p]===true),policy:()=> 'fixture-policy',provider:()=> 'fixture',providerName:()=> 'Fixture transcriber',handle:(p,text,{channel})=>{
  calls++;const row=state.users[p],slot=Number(text.match(/[12]/)[0])-1;row.providerConsent='fixture';row.consentPolicy='fixture-policy';
  if(text.startsWith('Schedule')){const old=row.lines[slot].schedule;row.lines[slot].schedule={enabled:true,channel,id:old?.id||crypto.randomUUID(),nextAt:old?.enabled?old.nextAt:Date.now(),startMode:'today-v1'};return 'Scheduled';}
  const id=crypto.randomUUID();row.lastJob=id;row.lastQueued=Date.now();fs.writeFileSync(path.join(root,'internet-queued',id+'.json'),JSON.stringify({id,owner:p,landline:row.lines[slot].number,carrier:row.lines[slot].carrier,replyChannel:channel,createdAt:Date.now(),status:'queued'}));return 'Queued';
 }};
 const tracker=new OrbitInternetTracker({requests,normalizeLine:x=>/^0[2-9][0-9]{7,8}$/.test(x)?x:null,normalizeCarrier:x=>['vodafone','we'].includes(x)?x:null});
 const change=(action,args={},p=PHONE)=>tracker.mutate(p,{request_id:crypto.randomUUID(),action,revision:tracker.view(p).revision,...args});
 const line=(slot,provider='vodafone')=>change('line',{slot,number:slot===1?'0223456789':'0334567890',provider});
 return {root,requests,tracker,change,line,get calls(){return calls;}};
}
test('both slots save/edit/delete using existing profile with no queued calls',t=>{
 const f=fixture(t);f.line(1);f.line(2,'we');assert.equal(f.tracker.view(PHONE).lines[1].provider,'we');assert.equal(f.calls,0);assert.equal(f.tracker.view(PHONE).history.length,0);
 f.change('line',{slot:2,number:'0445678901',provider:'vodafone'});f.change('delete_line',{slot:1});assert.equal(f.tracker.view(PHONE).lines[0].number,'0445678901');assert.equal(f.calls,0);
});
test('permissions respect owner and global gate; revoked contacts cannot check',t=>{
 const f=fixture(t);f.line(1);f.change('permission',{enabled:false});assert.equal(f.tracker.view(PHONE).allowed,false);
 assert.throws(()=>f.change('check',{slot:1,channel:'sms',confirmed:true,policy:'fixture-policy'}));assert.equal(f.calls,0);
 assert.throws(()=>f.change('permission',{enabled:false},OWNER));f.change('permission',{enabled:true});const s=f.requests.read();s.friendsEnabled=false;f.requests.save(s);assert.equal(f.tracker.view(PHONE).allowed,false);
});
test('check uses explicit WhatsApp/SMS routing and replay never queues twice',t=>{
 for(const channel of ['whatsapp','sms']){
  const f=fixture(t);f.line(1,channel==='sms'?'we':'vodafone');const body={request_id:crypto.randomUUID(),action:'check',revision:f.tracker.view(PHONE).revision,slot:1,channel,confirmed:true,policy:'fixture-policy'};
  assert.equal(f.tracker.mutate(PHONE,body).operation,'queued');assert.equal(f.tracker.view(PHONE).history[0].channel,channel);f.tracker.mutate(PHONE,body);assert.equal(f.calls,1);
  const restarted=new OrbitInternetTracker({requests:f.requests,normalizeLine:x=>x,normalizeCarrier:x=>x});restarted.mutate(PHONE,body);assert.equal(f.calls,1);
  assert.throws(()=>f.change('check',{slot:1,channel,confirmed:true,policy:'fixture-policy'}));assert.equal(f.calls,1);
 }
});
test('pending check blocks both slots, edits, and schedule enable',t=>{
 const f=fixture(t);f.line(1);f.line(2,'we');f.change('check',{slot:1,channel:'sms',confirmed:true,policy:'fixture-policy'});
 for(const action of ['check','line','delete_line','schedule'])assert.throws(()=>f.change(action,{slot:2,enabled:true,number:'0445678901',provider:'we',channel:'whatsapp',confirmed:true,policy:'fixture-policy'}));assert.equal(f.calls,1);
});
test('weekly schedule starts today, uses selected channel, retains due time on edits, disabling never checks',t=>{
 const f=fixture(t);f.line(1);f.change('schedule',{slot:1,enabled:true,channel:'sms',policy:'fixture-policy',confirmed:true});const due=f.tracker.view(PHONE).lines[0].nextAt;
 assert.ok(Math.abs(due-Date.now())<1000);assert.equal(fs.readdirSync(path.join(f.root,'internet-queued')).length,0);
 f.change('schedule',{slot:1,enabled:true,channel:'whatsapp',policy:'fixture-policy',confirmed:true});assert.equal(f.tracker.view(PHONE).lines[0].nextAt,due);
 f.change('schedule',{slot:1,enabled:false});assert.equal(f.tracker.view(PHONE).lines[0].weekly,false);assert.equal(f.calls,2);
});
test('unknown operation remains uncertain across restart and cannot be retried automatically',t=>{
 const f=fixture(t);f.line(1);const body={request_id:crypto.randomUUID(),action:'check',revision:f.tracker.view(PHONE).revision,slot:1,channel:'sms',confirmed:true,policy:'fixture-policy'};
 const hash=crypto.createHash('sha256').update(JSON.stringify([PHONE,body])).digest('hex');f.tracker.saveLedger({[body.request_id]:{hash,result:'unknown'}});
 assert.equal(f.tracker.mutate(PHONE,body).operation,'unknown');assert.equal(f.calls,0);
 assert.throws(()=>f.tracker.mutate(PHONE,{...body,channel:'whatsapp'}));
});
test('amounts never guess or relabel used, invalid, percentages or uncertain as remaining',()=>{
 const parts=[{amount:'12.5',unit:'GB'}];assert.deepEqual(remaining({ok:true,result:{parts}},'vodafone'),parts);
 assert.deepEqual(remaining({ok:true,result:{metric:'remaining',parts}},'we'),parts);
 for(const r of [{ok:false,result:{parts}},{ok:true,result:{metric:'used',parts}},{ok:true,result:{parts:[{amount:'10',unit:'%'}]}},{ok:true,result:{parts:[{amount:'ten',unit:'GB'}]}}])assert.equal(remaining(r,'vodafone'),null);
 assert.equal(remaining({ok:true,result:{parts}},'we'),null);
});
test('history and recording use existing short ID, scope ownership and seven-day expiry without checks',t=>{
 const f=fixture(t),id=crypto.randomUUID(),eventId='ABCD1234',at=Date.now();
 fs.writeFileSync(path.join(f.root,'internet-done',id+'.json'),JSON.stringify({id,owner:PHONE,landline:'0223456789',carrier:'vodafone',status:'completed',createdAt:at}));
 fs.writeFileSync(path.join(f.root,'internet-results',id+'.json'),JSON.stringify({ok:true,eventId,recordingFilename:eventId+'.wav',at,result:{parts:[{amount:'0',unit:'MB'}]},transcription:'private fixture'}));
 const audio=path.join(f.root,'internet-audio',eventId+'.wav');fs.writeFileSync(audio,Buffer.alloc(44));
 let result=f.tracker.view(PHONE);assert.equal(result.history[0].remaining[0].amount,'0');assert.equal(result.history[0].eventId,eventId);assert.equal(result.history[0].recordingAvailable,true);
 assert.equal(f.tracker.audio(PHONE,eventId).file,audio);assert.throws(()=>f.tracker.audio(OWNER,eventId));assert.throws(()=>f.tracker.audio(PHONE,'../secret'));
 assert.ok(!JSON.stringify(result).includes(f.root));assert.ok(!JSON.stringify(result).includes('transcription'));
 const old=new Date(at-8*86400000);fs.utimesSync(audio,old,old);assert.equal(f.tracker.view(PHONE).history[0].recordingExpired,true);assert.throws(()=>f.tracker.audio(PHONE,eventId));assert.equal(f.calls,0);
});
test('missing channel, stale settings, duplicate line, invalid provider and undisclosed policy cannot submit',t=>{
 const f=fixture(t);f.line(1);
 for(const body of [{slot:1,channel:'email',confirmed:true,policy:'fixture-policy'},{slot:1,channel:'sms',policy:'fixture-policy'},{slot:1,channel:'sms',confirmed:true,policy:'stale'}])assert.throws(()=>f.change('check',body));
 assert.throws(()=>f.change('line',{slot:2,number:'0223456789',provider:'we'}));assert.throws(()=>f.change('line',{slot:2,number:'0445678901',provider:'other'}));assert.equal(f.calls,0);
});

test('HTTP history and recording downloads never enqueue, and cross-contact audio is denied',async t=>{
 const f=fixture(t),id=crypto.randomUUID(),eventId='ABCD1234',at=Date.now();
 fs.writeFileSync(path.join(f.root,'internet-done',id+'.json'),JSON.stringify({id,owner:PHONE,landline:'0334567890',carrier:'we',status:'completed',createdAt:at}));
 fs.writeFileSync(path.join(f.root,'internet-results',id+'.json'),JSON.stringify({id,ok:true,eventId,recordingFilename:eventId+'.wav',at,result:{metric:'remaining',parts:[{amount:'5',unit:'GB'}]}}));
 const bytes=Buffer.alloc(44);bytes.write('RIFF');bytes.write('WAVE',8);
 fs.writeFileSync(path.join(f.root,'internet-audio',eventId+'.wav'),bytes);
 const server=http.createServer(async(req,res)=>{
  const reply=(status,body)=>{res.writeHead(status,{'Content-Type':'application/json'});res.end(JSON.stringify(body));};
  if(!await f.tracker.route(req,reply,res))reply(404,{});
 });
 await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
 t.after(()=>new Promise(resolve=>server.close(resolve)));
 const base='http://127.0.0.1:'+server.address().port+'/internet/contact/';
 const history=await fetch(base+PHONE);assert.equal(history.status,200);
 assert.equal((await history.json()).history[0].remaining[0].amount,'5');
 const audio=await fetch(base+PHONE+'/recordings/'+eventId);assert.equal(audio.status,200);
 assert.equal(audio.headers.get('cache-control'),'no-store');
 assert.deepEqual(Buffer.from(await audio.arrayBuffer()),bytes);
 const other=await fetch(base+OWNER+'/recordings/'+eventId);assert.equal(other.status,404);await other.text();
 const mutation=await fetch(base+PHONE+'/recordings/'+eventId,{method:'POST'});assert.equal(mutation.status,405);await mutation.text();
 const file=path.join(f.root,'internet-audio',eventId+'.wav');fs.unlinkSync(file);
 const expired=await fetch(base+PHONE+'/recordings/'+eventId);assert.equal(expired.status,410);await expired.text();
 assert.equal(f.calls,0);
});
