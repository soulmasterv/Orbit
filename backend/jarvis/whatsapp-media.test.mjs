import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import {WhatsAppInbox} from './whatsapp-inbox.mjs';
import {MEDIA_LIMIT} from './whatsapp-media.mjs';

const jpeg=Buffer.from([255,216,255,224,0,16,74,70,73,70]);
function fixture(){const dir=fs.mkdtempSync(path.join(os.tmpdir(),'orbit-media-'));assert.ok(path.resolve(dir).startsWith(path.resolve(os.tmpdir())+path.sep));return {dir,inbox:new WhatsAppInbox(path.join(dir,'inbox.json')),close(){fs.rmSync(dir,{recursive:true});}};}
async function* stream(bytes){yield bytes;}
function incoming(id='media',kind='imageMessage',extra={}){return {key:{id,remoteJid:'201000000001@s.whatsapp.net',fromMe:false},message:{[kind]:{mediaKey:Buffer.alloc(32,1),directPath:'/v/t62.1/fixture.enc',mimetype:kind==='imageMessage'?'image/jpeg':'application/pdf',fileName:'../report.pdf',fileLength:10,...extra}},messageTimestamp:1700000000};}
test('binary uploads are private, immutable, bounded and repeatable by same ID',async()=>{
 const f=fixture();try{const id=crypto.randomUUID();const media=await f.inbox.media.upload(id,'image','Photo.jpg','image/jpeg',stream(jpeg));assert.equal(media.size,jpeg.length);assert.deepEqual(await f.inbox.media.upload(id,'image','Photo.jpg','image/jpeg',stream(jpeg)),media);await assert.rejects(f.inbox.media.upload(id,'image','Other.jpg','image/jpeg',stream(jpeg)));assert.equal(fs.statSync(f.inbox.media.file(id)).size,jpeg.length);if(process.platform!=='win32')assert.equal(fs.statSync(f.inbox.media.file(id)).mode&0o077,0);}finally{f.close();}
});
test('invalid photo bytes and oversized streams leave no attachment or temporary file',async()=>{
 const f=fixture();try{await assert.rejects(f.inbox.media.upload(crypto.randomUUID(),'image','x.jpg','image/jpeg',stream(Buffer.from('<script>fixture</script>'))));async function* huge(){for(let i=0;i<26;i++)yield Buffer.alloc(1024*1024);}await assert.rejects(f.inbox.media.upload(crypto.randomUUID(),'document','x.bin','application/octet-stream',huge()));assert.equal(Object.keys(f.inbox.state.assets).length,0);assert.deepEqual(fs.readdirSync(f.inbox.media.directory),[]);assert.equal(f.inbox.media.uploading,false);}finally{f.close();}
});
test('media metadata is shown without exposing download keys or URLs',()=>{
 const f=fixture();try{f.inbox.record(incoming(),true);const message=f.inbox.messages('201000000001')[0];assert.equal(message.media.kind,'image');assert.equal(message.media.name,'.._report.pdf');assert.equal(message.text,'');assert.equal(f.inbox.chats()[0].latest,'Photo');const publicJSON=JSON.stringify(message);assert.ok(!/mediaKey|directPath|whatsapp\.net/.test(publicJSON));assert.equal(f.inbox.chats()[0].unread,1);}finally{f.close();}
});
test('view-once images and video wrappers are not archived',()=>{
 const f=fixture();try{f.inbox.record(incoming('once','imageMessage',{viewOnce:true}),true);const m=incoming('wrapper');m.message={viewOnceMessageV2:{message:m.message}};f.inbox.record(m,true);assert.equal(f.inbox.state.messages.length,0);assert.equal(Object.keys(f.inbox.state.assets).length,0);}finally{f.close();}
});
test('document-with-caption wrappers are supported without command execution',()=>{
 const f=fixture();try{const m=incoming('doc','documentMessage',{caption:'Fixture caption'});m.message={documentWithCaptionMessage:{message:m.message}};f.inbox.record(m,true);assert.equal(f.inbox.state.messages[0].text,'Fixture caption');assert.equal(f.inbox.state.messages[0].media.kind,'document');}finally{f.close();}
});
test('incoming downloads restore private Buffer keys across restart and constrain sources',async()=>{
 const f=fixture();try{f.inbox.record(incoming(),true);const id=f.inbox.state.messages[0].media.id;const next=new WhatsAppInbox(f.inbox.file);let downloads=0;const file=await next.media.fetch(id,async m=>{downloads++;assert.ok(Buffer.isBuffer(m.message.imageMessage.mediaKey));assert.equal(m.message.imageMessage.mediaKey.length,32);assert.equal(m.message.imageMessage.url,'https://mmg.whatsapp.net/v/t62.1/fixture.enc');return stream(jpeg);},{});assert.deepEqual(fs.readFileSync(file),jpeg);await next.media.fetch(id,()=>{throw Error('Must use cached file');},{});assert.equal(downloads,1);const bad=incoming('bad');delete bad.message.imageMessage.directPath;bad.message.imageMessage.url='http://127.0.0.1/private';next.record(bad,true);assert.equal(next.state.messages.at(-1).media.state,'unavailable');}finally{f.close();}
});
test('media send uncertainty persists without reuploading or resending',async()=>{
 const f=fixture();try{const id=crypto.randomUUID();await f.inbox.media.upload(id,'image','Photo.jpg','image/jpeg',stream(jpeg));const request={request_id:crypto.randomUUID(),destination:'01000000001',text:'Fixture',media_id:id};let sends=0;const socket={sendMessage:async(jid,body)=>{sends++;assert.equal(jid,'201000000001@s.whatsapp.net');assert.equal(body.image.url,f.inbox.media.file(id));assert.equal(body.caption,'Fixture');throw Error('Connection lost');}};assert.equal((await f.inbox.send(request,socket)).status,'unknown');const next=new WhatsAppInbox(f.inbox.file);await next.send(request,socket);assert.equal(sends,1);await assert.rejects(next.send({...request,media_id:crypto.randomUUID()},socket));assert.equal(sends,1);}finally{f.close();}
});
test('oversized incoming media is described but never downloaded',async()=>{
 const f=fixture();try{f.inbox.record(incoming('large','videoMessage',{fileLength:MEDIA_LIMIT+1}),true);const media=f.inbox.state.messages[0].media;assert.equal(media.state,'too_large');let downloads=0;await assert.rejects(f.inbox.media.fetch(media.id,()=>{downloads++;},{}));assert.equal(downloads,0);}finally{f.close();}
});
test('existing text-only ledger claims survive the media upgrade',async()=>{
 const f=fixture();try{const request={request_id:crypto.randomUUID(),destination:'201000000001',text:'Fixture'};const digest=crypto.createHash('sha256').update(JSON.stringify([request.destination,request.text])).digest('hex');f.inbox.state.requests[request.request_id]={digest,status:'unknown'};f.inbox.save();const next=new WhatsAppInbox(f.inbox.file);let sends=0;assert.equal((await next.send(request,{sendMessage:()=>{sends++;}})).status,'unknown');assert.equal(sends,0);}finally{f.close();}
});
test('prepared photo thumbnails are reused for WhatsApp delivery',async()=>{
 const f=fixture();try{const id=crypto.randomUUID();await f.inbox.media.upload(id,'image','Photo.jpg','image/jpeg',stream(jpeg),jpeg.toString('base64'));const content=f.inbox.media.content(id,'Fixture');assert.deepEqual(content.jpegThumbnail,jpeg);assert.equal(content.mimetype,'image/jpeg');}finally{f.close();}
});
