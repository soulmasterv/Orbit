import fs from 'node:fs';
import crypto from 'node:crypto';
import path from 'node:path';
import {WhatsAppMediaStore,mediaRoute} from './whatsapp-media.mjs';

export function phone(value) {
  if (typeof value !== 'string' || !/^[+\d\s().-]+$/.test(value)) throw Error('Invalid recipient');
  let n=value.replace(/[\s().-]/g,'');
  if(n.startsWith('00'))n='+'+n.slice(2);
  if(/^01\d{9}$/.test(n))n='20'+n.slice(1);
  n=n.replace(/^\+/,'');
  if(!/^[1-9]\d{7,14}$/.test(n))throw Error('Invalid recipient');
  return n;
}
const statusName=n=>({0:'failed',1:'pending',2:'sent',3:'delivered',4:'read',5:'read'}[n]||'unknown');
export class WhatsAppInbox {
  constructor(file){
    this.file=file;
    this.state=fs.existsSync(file)?JSON.parse(fs.readFileSync(file,'utf8')):{messages:[],requests:{},seen:{},names:{},read:{}};
    this.connected=false;
    this.media=new WhatsAppMediaStore(path.dirname(file),this.state,()=>this.save());
    for(const r of Object.values(this.state.requests))if(r.status==='pending')r.status='unknown';
    this.save();
  }
  save(){fs.writeFileSync(this.file+'.tmp',JSON.stringify(this.state),{mode:0o600});fs.renameSync(this.file+'.tmp',this.file);}
  record(m,live=false,uploadedAssetID=null){
    const jid=m.key?.remoteJidAlt?.endsWith('@s.whatsapp.net')?m.key.remoteJidAlt:m.key?.remoteJid;
    if(!/^\d{8,15}@s\.whatsapp\.net$/.test(jid||'')||!m.key?.id)return;
    let body=m.message;
    for(let depth=0;depth<3;depth++){
      if(body?.viewOnceMessage||body?.viewOnceMessageV2||body?.viewOnceMessageV2Extension)return;
      const next=body?.ephemeralMessage?.message||body?.documentWithCaptionMessage?.message;
      if(!next)break;body=next;
    }
    const text=body?.conversation||body?.extendedTextMessage?.text||body?.imageMessage?.caption||body?.videoMessage?.caption||body?.documentMessage?.caption||'';
    const hasMedia=body?.imageMessage||body?.videoMessage||body?.documentMessage;
    if(typeof text!=='string'||(!text&&!hasMedia&&!uploadedAssetID)||hasMedia?.viewOnce)return;
    const id=jid+':'+m.key.id;
    if(this.state.seen[id]){
      const existing=this.state.messages.find(row=>row.chat===jid.split('@')[0]&&row.id===m.key.id);
      const asset=uploadedAssetID&&this.state.assets[uploadedAssetID];
      if(existing&&asset){if(existing.media&&this.state.assets[existing.media.id]?.source)asset.source=this.state.assets[existing.media.id].source;existing.media=this.media.public(asset);this.save();}
      return;
    }
    if(Object.keys(this.state.seen).length>=100000)throw Error('Inbox capacity reached');
    const chat=jid.split('@')[0],outgoing=m.key.fromMe===true;
    if(!outgoing&&typeof m.pushName==='string')this.state.names[chat]=m.pushName.slice(0,100);
    const media=uploadedAssetID&&this.state.assets[uploadedAssetID]?this.media.public(this.state.assets[uploadedAssetID]):this.media.register(m,body);
    this.state.seen[id]=true;
    this.state.messages.push({id:m.key.id,chat,text:text.slice(0,12000),...(media?{media}:{}),outgoing,at:Number(m.messageTimestamp)||Math.floor(Date.now()/1000),status:outgoing?statusName(m.status):'received',unread:live&&!outgoing});
    this.state.messages=this.state.messages.slice(-10000);
    let characters=this.state.messages.reduce((sum,m)=>sum+m.text.length,0);
    while(characters>5_000_000&&this.state.messages.length>1)characters-=this.state.messages.shift().text.length;
    this.save();
  }
  updates(items){
    for(const {key,update} of items){
      const message=this.state.messages.find(m=>m.id===key?.id&&m.outgoing&&(!key.remoteJid?.endsWith('@s.whatsapp.net')||m.chat===key.remoteJid.split('@')[0]));
      if(!message||typeof update?.status!=='number')continue;
      const next=statusName(update.status),rank={unknown:0,pending:1,sent:2,delivered:3,read:4};
      if(next==='failed'||(rank[next]??0)>(rank[message.status]??0))message.status=next;
    }this.save();
  }
  chats(){
    const chats=new Map();
    for(const m of this.state.messages){const preview=m.media?((m.media.kind==='image'?'Photo':m.media.kind==='video'?'Video':m.media.name)+(m.text?' · '+m.text:'')):m.text;let c=chats.get(m.chat);if(!c)c={id:m.chat,name:this.state.names[m.chat]||m.chat,latest:preview.slice(0,240),at:m.at,unread:0};if(m.at>=c.at){c.latest=preview.slice(0,240);c.at=m.at;}if(m.unread)c.unread++;chats.set(m.chat,c);}
    return [...chats.values()].sort((a,b)=>b.at-a.at).slice(0,200);
  }
  messages(chat,before){chat=phone(chat);let rows=this.state.messages.filter(m=>m.chat===chat).sort((a,b)=>a.at-b.at);if(before){const end=rows.findIndex(m=>m.id===before);rows=end<0?[]:rows.slice(0,end);}return rows.slice(-50);}
  markRead(chat){chat=phone(chat);for(const m of this.state.messages)if(m.chat===chat)m.unread=false;this.save();}
  async send(input,socket){
    const chat=phone(input.destination),id=input.request_id,text=input.text,mediaID=input.media_id;
    if(mediaID!==undefined&&mediaID!==null&&(typeof mediaID!=='string'||!/^[a-f0-9-]{36}$/i.test(mediaID)))throw Error('Invalid attachment');
    if(!/^[a-f0-9-]{36}$/i.test(id||'')||typeof text!=='string'||(!text.trim()&&!mediaID)||text.length>12000)throw Error('Invalid message');
    if(mediaID&&text.length>1024)throw Error('Caption exceeds 1,024 characters');
    // Preserve the original text-only digest so existing persisted IDs retain their contract.
    const digest=crypto.createHash('sha256').update(JSON.stringify(mediaID?[chat,text,mediaID]:[chat,text])).digest('hex');
    const old=this.state.requests[id];
    if(old){if(old.digest!==digest)throw Error('Request ID conflict');return old;}
    if(!socket)throw Error('WhatsApp is disconnected');
    const content=mediaID?this.media.content(mediaID,text):{text};
    if(Object.keys(this.state.requests).length>=100000)throw Error('Send ledger full');
    const row={request_id:id,digest,status:'pending',chat};
    this.state.requests[id]=row;this.save();
    try{
      if(mediaID)this.media.inUse.add(mediaID);
      const sent=await socket.sendMessage(chat+'@s.whatsapp.net',content);
      row.message_id=sent?.key?.id;row.status=sent?.key?.id?'sent':'unknown';
      if(sent)this.record({...sent,message:sent.message||{conversation:text},status:2},false,mediaID);
    }catch{row.status='unknown';}finally{if(mediaID)this.media.inUse.delete(mediaID);}
    this.save();return row;
  }
}

export async function inboxRoute(req,reply,{inbox,getSocket,key,res,download}){
  const url=new URL(req.url,'http://localhost');
  if(!url.pathname.startsWith('/inbox'))return false;
  try{
    if(res&&await mediaRoute(req,res,reply,{inbox,getSocket,download}))return true;
    if(req.method==='GET'&&url.pathname==='/inbox')reply(200,{connected:inbox.connected,chats:inbox.chats()});
    else if(req.method==='GET'&&/^\/inbox\/requests\/[a-f0-9-]{36}$/i.test(url.pathname)){
      const row=inbox.state.requests[url.pathname.split('/').pop()];reply(row?200:404,row?{request_id:row.request_id,status:row.status,message_id:row.message_id}:{error:'not_found'});
    }else if(req.method==='GET'&&/^\/inbox\/\d{8,15}$/.test(url.pathname)){
      const chat=phone(url.pathname.split('/').pop()),before=url.searchParams.get('before')||null;
      reply(200,{connected:inbox.connected,messages:inbox.messages(chat,before)});
    }else if(req.method==='POST'){
      let raw='';for await(const chunk of req){raw+=chunk;if(Buffer.byteLength(raw)>60000){reply(413,{});return true;}}
      const input=JSON.parse(raw);
      if(url.pathname==='/inbox/send'){
        const row=await inbox.send(input,getSocket());reply(200,{request_id:row.request_id,status:row.status,message_id:row.message_id});
      }else if(url.pathname==='/inbox/read'){inbox.markRead(input.destination);reply(200,{status:'ok'});}
      else reply(404,{});
    }else reply(405,{});
  }catch{reply(400,{error:'Request unavailable. Check connection and message status before sending again.'});}
  return true;
}
