import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {WhatsAppInbox,phone,inboxRoute} from './whatsapp-inbox.mjs';
const fixture=()=>{const dir=fs.mkdtempSync(path.join(os.tmpdir(),'orbit-inbox-'));return {dir,inbox:new WhatsAppInbox(path.join(dir,'inbox.json'))};};
const message=(id='fixture',fromMe=false)=>({key:{id,remoteJid:'201000000001@s.whatsapp.net',fromMe},message:{conversation:'Fixture text'},messageTimestamp:1700000000});
test('recipients normalize local Egyptian, spaces and international; reject JIDs and injection',()=>{
  assert.equal(phone('010 0000 0001'),'201000000001');assert.equal(phone('+44 7700 900123'),'447700900123');
  for(const n of ['abc','123','a@s.whatsapp.net','01/111111111','+000000000',''])assert.throws(()=>phone(n));
});
test('incoming deduplicates persistently, unread clears, no command interface',()=>{
 const {dir,inbox}=fixture();try{inbox.record(message(),true);inbox.record(message(),true);assert.equal(inbox.chats()[0].unread,1);inbox.markRead('201000000001');assert.equal(inbox.chats()[0].unread,0);const next=new WhatsAppInbox(inbox.file);next.record(message(),true);assert.equal(next.state.messages.length,1);assert.equal(typeof next.command,'undefined');}finally{fs.rmSync(dir,{recursive:true});}
});
test('groups and unresolved LID identities are excluded; direct text only',()=>{
 const {dir,inbox}=fixture();try{const m=message();m.key.remoteJid='123@g.us';inbox.record(m,true);m.key.remoteJid='123@lid';inbox.record(m,true);assert.equal(inbox.chats().length,0);m.key.remoteJidAlt='201000000001@s.whatsapp.net';inbox.record(m,true);assert.equal(inbox.chats().length,1);}finally{fs.rmSync(dir,{recursive:true});}
});
test('send claims before transmission, repeated taps return same result, changed text is rejected',async()=>{
 const {dir,inbox}=fixture();let sends=0;const r={destination:'01000000001',text:'Fixture',request_id:'11111111-1111-4111-8111-111111111111'};
 try{const socket={sendMessage:async()=>{sends++;assert.equal(JSON.parse(fs.readFileSync(inbox.file)).requests[r.request_id].status,'pending');return {...message('out',true),message:{conversation:r.text}};}};assert.equal((await inbox.send(r,socket)).status,'sent');await inbox.send(r,socket);assert.equal(sends,1);await assert.rejects(inbox.send({...r,text:'Other'},socket));assert.equal(sends,1);}finally{fs.rmSync(dir,{recursive:true});}
});
test('uncertain send and process restart never resend a claimed request',async()=>{
 const {dir,inbox}=fixture();let sends=0;const r={destination:'01000000001',text:'Fixture',request_id:'22222222-2222-4222-8222-222222222222'};
 try{const socket={sendMessage:async()=>{sends++;throw Error('connection lost');}};assert.equal((await inbox.send(r,socket)).status,'unknown');const next=new WhatsAppInbox(inbox.file);await next.send(r,socket);assert.equal(sends,1);next.state.requests[r.request_id].status='pending';next.save();assert.equal(new WhatsAppInbox(inbox.file).state.requests[r.request_id].status,'unknown');}finally{fs.rmSync(dir,{recursive:true});}
});
test('receipts are monotonic and never invent read status',()=>{
 const {dir,inbox}=fixture();try{const m=message('out',true);m.status=2;inbox.record(m);inbox.updates([{key:m.key,update:{status:4}},{key:m.key,update:{status:3}}]);assert.equal(inbox.state.messages[0].status,'read');}finally{fs.rmSync(dir,{recursive:true});}
});
test('disconnected socket rejects before claiming request',async()=>{
 const {dir,inbox}=fixture();try{await assert.rejects(inbox.send({destination:'01000000001',text:'Fixture',request_id:'33333333-3333-4333-8333-333333333333'},null));assert.equal(Object.keys(inbox.state.requests).length,0);}finally{fs.rmSync(dir,{recursive:true});}
});
