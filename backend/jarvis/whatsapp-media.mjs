import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {pipeline} from 'node:stream/promises';

export const MEDIA_LIMIT=25*1024*1024;
const QUOTA=500*1024*1024;
const UUID=/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i;
const kinds={image:'imageMessage',video:'videoMessage',document:'documentMessage'};
function writeAll(fd,chunk){let offset=0;while(offset<chunk.length){const count=fs.writeSync(fd,chunk,offset,chunk.length-offset);if(count<=0)throw Error('Attachment storage failed');offset+=count;}}
export function filename(value){
  return String(value||'Attachment').replace(/[\\/\x00-\x1f\x7f]/g,'_').slice(0,120)||'Attachment';
}
function validBytes(bytes,kind){
  if(kind==='document')return true;
  if(kind==='image')return bytes.subarray(0,3).equals(Buffer.from([255,216,255]))||bytes.subarray(0,8).equals(Buffer.from([137,80,78,71,13,10,26,10]))||bytes.subarray(0,6).toString().startsWith('GIF8')||(bytes.subarray(0,4).toString()==='RIFF'&&bytes.subarray(8,12).toString()==='WEBP');
  return bytes.subarray(4,8).toString()==='ftyp'||bytes.subarray(0,4).equals(Buffer.from([26,69,223,163]));
}
function sourceMessage(message,key){
  // Never use an arbitrary message-supplied URL for a server-side download.
  const original=message.message[key];
  if(!(original.mediaKey instanceof Uint8Array)||original.mediaKey.length!==32)throw Error('Invalid media key');
  const fields=Object.fromEntries(['url','directPath','mediaKey','fileEncSha256','fileSha256','mimetype','fileLength','mediaKeyTimestamp'].filter(name=>original[name]!==undefined).map(name=>[name,original[name]]));
  const raw=restoreMedia({key:message.key,message:{[key]:fields}}),media=raw.message[key];
  if(typeof media.directPath==='string'&&/^\/v\/[A-Za-z0-9_./?=&%+-]{1,4000}$/.test(media.directPath)&&!media.directPath.includes('..'))media.url=new URL(media.directPath,'https://mmg.whatsapp.net').href;
  else {
    if(typeof media.url!=='string'||media.url.length>4096)throw Error('Invalid media source');
    const url=new URL(media.url);
    if(url.protocol!=='https:'||url.port||url.username||url.password||!(url.hostname==='mmg.whatsapp.net'||url.hostname.endsWith('.whatsapp.net')))throw Error('Invalid media source');
  }
  return raw;
}
function restoreMedia(value){return JSON.parse(JSON.stringify(value,(_,item)=>item instanceof Uint8Array?{type:'Buffer',data:Array.from(item)}:item),(_,item)=>item?.type==='Buffer'&&Array.isArray(item.data)?Buffer.from(item.data):item);}
export class WhatsAppMediaStore {
  constructor(directory,state,save){
    this.directory=path.join(directory,'orbit-media');this.state=state;this.save=save;this.uploading=false;this.pending=new Map();this.inUse=new Set();
    if(fs.existsSync(this.directory)&&fs.lstatSync(this.directory).isSymbolicLink())throw Error('Invalid media directory');
    fs.mkdirSync(this.directory,{recursive:true,mode:0o700});
    for(const name of fs.readdirSync(this.directory))if(/^[a-f0-9-]{36}\.(tmp|download)$/i.test(name))fs.rmSync(path.join(this.directory,name),{force:true});
    state.assets??={};
    this.clean();
  }
  file(id){if(!UUID.test(id))throw Error('Invalid attachment');const file=path.join(this.directory,id);if(fs.existsSync(file)&&fs.lstatSync(file).isSymbolicLink())throw Error('Invalid attachment');return file;}
  public(asset){return {id:asset.id,kind:asset.kind,name:asset.name,mime:asset.mime,size:asset.size,...(asset.thumbnail?{thumbnail:asset.thumbnail}:{}),state:asset.size>MEDIA_LIMIT?'too_large':asset.unavailable?'unavailable':'available'};}
  register(message,body){
    const kind=Object.keys(kinds).find(k=>body[kinds[k]]);
    if(!kind)return null;
    const media=body[kinds[kind]];
    if(media.viewOnce)return null;
    if(Object.keys(this.state.assets).length>=20000)throw Error('Attachment capacity reached');
    const id=crypto.randomUUID(),size=Number(media.fileLength);
    const asset={id,kind,name:filename(media.fileName||(kind==='image'?'Photo.jpg':kind==='video'?'Video.mp4':'Attachment')),mime:String(media.mimetype||'application/octet-stream').slice(0,100),size:Number.isFinite(size)&&size>=0?size:null,at:Date.now()};
    if(media.jpegThumbnail instanceof Uint8Array&&media.jpegThumbnail.length<=4000&&validBytes(Buffer.from(media.jpegThumbnail),'image'))asset.thumbnail=Buffer.from(media.jpegThumbnail).toString('base64');
    try { asset.source=sourceMessage({key:message.key,message:{[kinds[kind]]:media}},kinds[kind]); }catch{asset.unavailable=true;}
    this.state.assets[id]=asset;
    return this.public(asset);
  }
  clean(exclude){
    const files=Object.values(this.state.assets).filter(a=>fs.existsSync(this.file(a.id))).sort((a,b)=>a.at-b.at);
    let total=files.reduce((sum,a)=>sum+fs.statSync(this.file(a.id)).size,0);
    for(const a of files){if(a.id===exclude||this.inUse.has(a.id))continue;const file=this.file(a.id),size=fs.statSync(file).size;if(total>QUOTA||a.at<Date.now()-7*86400000){fs.unlinkSync(file);total-=size;}}
  }
  async upload(id,kind,name,mime,stream,thumbnail=null){
    if(!UUID.test(id)||!kinds[kind]||typeof mime!=='string'||mime.length>100||!/^[A-Za-z0-9!#$&^_.+-]+\/[A-Za-z0-9!#$&^_.+-]{1,80}$/.test(mime))throw Error('Invalid attachment');
    if(this.uploading)throw Error('An upload is already in progress');
    if(Object.keys(this.state.assets).length>=20000&&!this.state.assets[id])throw Error('Attachment capacity reached');
    this.uploading=true;
    const temporary=this.file(id)+'.tmp';let size=0,head=Buffer.alloc(0);const hash=crypto.createHash('sha256');
    try{
      const fd=fs.openSync(temporary,'wx',0o600);
      try { for await(const chunk of stream){size+=chunk.length;if(size>MEDIA_LIMIT)throw Error('Attachment exceeds 25 MB');if(head.length<16)head=Buffer.concat([head,chunk]).subarray(0,16);hash.update(chunk);writeAll(fd,chunk);} }finally{fs.closeSync(fd);}
      if(!size||!validBytes(head,kind))throw Error('Unsupported media format');
      const digest=hash.digest('hex'),old=this.state.assets[id];
      if(old){if(old.digest!==digest||old.kind!==kind||old.name!==filename(name)||old.mime!==mime)throw Error('Attachment ID conflict');fs.unlinkSync(temporary);return this.public(old);}
      fs.renameSync(temporary,this.file(id));
      const asset={id,kind,name:filename(name),mime,size,digest,at:Date.now()};
      if(thumbnail){const bytes=Buffer.from(thumbnail,'base64');if(bytes.length<=4000&&validBytes(bytes,'image'))asset.thumbnail=bytes.toString('base64');}
      this.state.assets[id]=asset;this.clean(id);this.save();return this.public(asset);
    }finally{this.uploading=false;fs.rmSync(temporary,{force:true});}
  }
  async fetch(id,download,socket){
    const asset=this.state.assets[id];
    if(!asset||asset.unavailable||asset.size>MEDIA_LIMIT)throw Error('Attachment unavailable');
    const file=this.file(id);
    if(fs.existsSync(file))return file;
    if(!asset.source||!socket||!download)throw Error('Attachment expired or unavailable');
    if(this.pending.has(id))return this.pending.get(id);
    if(this.pending.size>=2)throw Error('Another attachment is downloading');
    const task=(async()=>{
      const temporary=file+'.download';let count=0;
      this.inUse.add(id);
      try{
        const stream=await download(restoreMedia(asset.source),socket),fd=fs.openSync(temporary,'wx',0o600);
        try{for await(const chunk of stream){count+=chunk.length;if(count>MEDIA_LIMIT)throw Error('Attachment exceeds 25 MB');writeAll(fd,chunk);}}finally{fs.closeSync(fd);}
        if(!count)throw Error('Empty attachment');
        fs.renameSync(temporary,file);asset.size=count;asset.at=Date.now();this.clean(id);this.save();return file;
      }finally{this.inUse.delete(id);fs.rmSync(temporary,{force:true});this.pending.delete(id);}
    })();
    this.pending.set(id,task);return task;
  }
  content(id,caption){
    const asset=this.state.assets[id];
    if(!asset||!fs.existsSync(this.file(id)))throw Error('Upload the attachment again');
    const source={url:this.file(id)};
    if(asset.kind==='image')return {image:source,caption,mimetype:asset.mime};
    if(asset.kind==='video')return {video:source,caption,mimetype:asset.mime};
    return {document:source,caption,mimetype:asset.mime,fileName:asset.name};
  }
}

export async function mediaRoute(req,res,reply,{inbox,getSocket,download}){
  const url=new URL(req.url,'http://localhost'),match=/^\/inbox\/media\/([a-f0-9-]{36})$/i.exec(url.pathname);
  if(!match)return false;
  const id=match[1];
  try{
    if(req.method==='PUT'){
      if(!Number.isFinite(Number(req.headers['content-length']))||Number(req.headers['content-length'])>MEDIA_LIMIT){reply(413,{error:'Attachment exceeds 25 MB'});return true;}
      const asset=await inbox.media.upload(id,url.searchParams.get('kind'),url.searchParams.get('name'),url.searchParams.get('mime'),req,req.headers['x-orbit-thumbnail']);
      reply(200,asset);
    }else if(req.method==='GET'){
      const file=await inbox.media.fetch(id,download,getSocket());
      res.writeHead(200,{'Content-Type':'application/octet-stream','Content-Length':fs.statSync(file).size,'Content-Disposition':'attachment','Cache-Control':'no-store','X-Content-Type-Options':'nosniff'});
      await pipeline(fs.createReadStream(file),res);
    }else reply(405,{});
  }catch{if(res.headersSent)res.destroy();else reply(400,{error:'Attachment unavailable. Check the format and 25 MB limit.'});}
  return true;
}
