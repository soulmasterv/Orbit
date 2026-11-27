// Authenticated HTTP wiring delegates to this facade over the existing tracker.
// Never tick schedules, call delivery(), or enqueue work during a read.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
const UUID=/^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/i;
const EVENT=/^[A-F0-9]{8}$/;
const WEEK=7*86400000;
export class TrackerError extends Error { constructor(message,status=422){super(message);this.status=status;} }
function readJSON(file){const s=fs.lstatSync(file);if(!s.isFile()||s.isSymbolicLink()||s.size>262144)throw new TrackerError('Stored result unavailable',503);return JSON.parse(fs.readFileSync(file,'utf8'));}
function ms(value){if(typeof value==='number'&&Number.isFinite(value))return value<1e12?value*1000:value;const n=Date.parse(value);return Number.isFinite(n)?n:null;}
export function remaining(result,carrier){
 const r=result?.result;
 // Legacy Vodafone's validated result contract is remaining-only. WE must declare its metric.
 if(result?.ok!==true||!r||r.metric==='used'||(carrier==='we'&&r.metric!=='remaining')||!Array.isArray(r.parts)||r.parts.length<1||r.parts.length>2)return null;
 if(r.metric!==undefined&&r.metric!=='remaining')return null;
 if(r.parts.some(p=>typeof p.amount!=='string'||!/^\d{1,6}(?:\.\d{1,3})?$/.test(p.amount)||!['GB','MB'].includes(p.unit)))return null;
 return r.parts.map(p=>({amount:p.amount,unit:p.unit}));
}
export class OrbitInternetTracker {
 constructor({requests,normalizeLine,normalizeCarrier,now=Date.now}){this.requests=requests;this.root=requests.root;this.normalizeLine=normalizeLine;this.normalizeCarrier=normalizeCarrier;this.now=now;this.operations=path.join(this.root,'internet-orbit-operations.json');}
 phone(value){if(typeof value!=='string'||! /^[1-9][0-9]{7,14}$/.test(value))throw new TrackerError('Invalid contact');return value;}
 directory(){
  const s=this.requests.read(),phones=[...new Set([...Object.keys(s.users||{}),...Object.keys(s.invites||{}),...this.requests.owners])].filter(p=>/^[1-9][0-9]{7,14}$/.test(p)).sort();
  if(phones.length>2000)throw new TrackerError('Contact list unavailable',503);
  return {version:1,contacts:phones.map(phone=>{
   const row=s.users?.[phone]||{},lines=row.lines||(row.landline?[{number:row.landline,carrier:'vodafone'}]:[]);
   return {phone,name:typeof row.name==='string'?row.name.slice(0,120):null,allowed:this.requests.allowed(phone,s),lines:lines.slice(0,2).filter(l=>typeof l.number==='string').map(l=>({number:l.number,provider:l.carrier||'vodafone'}))};
  })};
 }
 jobs(phone){
  const jobs=new Map();
  for(const [dir,status] of [['internet-done','unknown'],['internet-processing','running'],['internet-queued','queued']]){
   const folder=path.join(this.root,dir);if(!fs.existsSync(folder))continue;
   const names=fs.readdirSync(folder);if(names.length>10000)throw new TrackerError('History unavailable',503);
   for(const name of names){if(!name.endsWith('.json')||!UUID.test(name.slice(0,-5)))continue;
    const j=readJSON(path.join(folder,name));if(j.owner===phone&&j.id===name.slice(0,-5))jobs.set(j.id,{...j,status:dir==='internet-done'?j.status||status:status});
   }
  }
  return [...jobs.values()].sort((a,b)=>(ms(b.createdAt)||0)-(ms(a.createdAt)||0));
 }
 result(job){const file=path.join(this.root,'internet-results',job.id+'.json');return fs.existsSync(file)?readJSON(file):null;}
 recording(job,result){
  const event=result?.eventId;if(!EVENT.test(event||'')||result.recordingFilename!==event+'.wav')return null;
  const file=path.join(this.root,'internet-audio',event+'.wav');if(!fs.existsSync(file))return null;
  const s=fs.lstatSync(file),at=ms(result.at)||ms(job.createdAt);
  if(!s.isFile()||s.isSymbolicLink()||s.size<44||s.size>50*1024*1024||!at||this.now()-at>=WEEK||this.now()-s.mtimeMs>=WEEK)return null;
  return {file,size:s.size};
 }
 revision(state,phone){return crypto.createHash('sha256').update(JSON.stringify([state.users?.[phone]??null,state.invites?.[phone]??false,state.friendsEnabled===true,this.requests.policy()])).digest('hex');}
 view(phone){
  this.phone(phone);const s=this.requests.read(),row=s.users?.[phone]||{},owner=this.requests.owners.includes(phone),jobs=this.jobs(phone);
  const lines=row.lines|| (row.landline?[{number:row.landline,carrier:'vodafone'}]:[]);
  return {version:1,phone,allowed:this.requests.allowed(phone,s),permissionGranted:owner||s.invites?.[phone]===true,permissionEditable:!owner,friendChecksEnabled:s.friendsEnabled===true,revision:this.revision(s,phone),policy:this.requests.policy(),audioProvider:this.requests.providerName(),
   lines:[0,1].map(i=>({slot:i+1,number:lines[i]?.number??null,provider:lines[i]?.carrier??null,weekly:!!lines[i]?.schedule?.enabled,nextAt:lines[i]?.schedule?.enabled?lines[i].schedule.nextAt??null:null,channel:lines[i]?.schedule?.channel??null})),
   pending:jobs.some(j=>['queued','running'].includes(j.status)),history:jobs.slice(0,100).map(j=>{
    const r=this.result(j),parts=remaining(r,j.carrier),recording=this.recording(j,r);
    return {id:j.id,eventId:EVENT.test(r?.eventId||'')?r.eventId:null,at:ms(r?.at)||ms(j.createdAt),number:j.landline,provider:j.carrier||'vodafone',status:j.status,remaining:parts,recordingAvailable:!!recording,recordingExpired:!recording&&!['queued','running'].includes(j.status),channel:j.replyChannel==='sms'?'sms':'whatsapp'};
   })};
 }
 ledger(){return fs.existsSync(this.operations)?readJSON(this.operations):{};}
 saveLedger(value){const temp=this.operations+'.tmp';fs.writeFileSync(temp,JSON.stringify(value),{mode:0o600});fs.renameSync(temp,this.operations);}
 mutate(phone,body){
  this.phone(phone);
  if(!body||typeof body!=='object'||!UUID.test(body.request_id||'')||!['permission','line','delete_line','check','schedule'].includes(body.action))throw new TrackerError('Invalid request');
  const allowedKeys={permission:['enabled'],line:['slot','number','provider'],delete_line:['slot'],check:['slot','channel','policy','confirmed'],schedule:['slot','enabled','channel','policy','confirmed']}[body.action];
  if(Object.keys(body).some(k=>!['request_id','action','revision',...allowedKeys].includes(k)))throw new TrackerError('Invalid request');
  const ledger=this.ledger(),hash=crypto.createHash('sha256').update(JSON.stringify([phone,body])).digest('hex');
  if(ledger[body.request_id]){if(ledger[body.request_id].hash!==hash)throw new TrackerError('Request changed',409);return {...this.view(phone),operation:ledger[body.request_id].result??'unknown'};}
  if(Object.keys(ledger).length>=1000)throw new TrackerError('Operation history is full',503);
  const s=this.requests.read();if(body.revision!==this.revision(s,phone))throw new TrackerError('Settings changed. Refresh first.',409);
  if(body.action==='permission'){
   if(typeof body.enabled!=='boolean'||this.requests.owners.includes(phone))throw new TrackerError('Owner access cannot be changed');
  }else if(![1,2].includes(body.slot))throw new TrackerError('Choose line 1 or 2');
  const jobs=this.jobs(phone),pending=jobs.some(j=>['queued','running'].includes(j.status));
  if(pending&&(['line','delete_line','check'].includes(body.action)||(body.action==='schedule'&&body.enabled)))throw new TrackerError('A check is pending. Wait for its result.',409);
  s.users??={};s.invites??={};const row=s.users[phone]??={};row.lines??=row.landline?[{number:row.landline,carrier:'vodafone',planGb:row.planGb||null}]:[];
  const index=body.slot-1,line=row.lines[index];
  if(body.action==='line'){
   const number=this.normalizeLine(body.number),carrier=this.normalizeCarrier(body.provider);
   if(!number||!carrier||index>row.lines.length||row.lines.some((l,i)=>i!==index&&l.number===number))throw new TrackerError('Invalid or duplicate landline');
  }else if(['delete_line','check','schedule'].includes(body.action)&&!line)throw new TrackerError('Save that line first');
  if(['check','schedule'].includes(body.action)){
   if(body.action==='schedule'&&typeof body.enabled!=='boolean')throw new TrackerError('Invalid schedule');
   if(body.action==='check'||body.enabled){
    if(!['sms','whatsapp'].includes(body.channel)||body.confirmed!==true||body.policy!==this.requests.policy())throw new TrackerError('Review audio processing and delivery first');
    if(!this.requests.allowed(phone,s))throw new TrackerError('Internet checks are not allowed for this contact',403);
   }
  }
  ledger[body.request_id]={hash,result:'unknown'};this.saveLedger(ledger);
  let result='saved';
  if(body.action==='permission'){if(body.enabled)s.invites[phone]=true;else delete s.invites[phone];this.requests.save(s);}
  if(body.action==='line'||body.action==='delete_line'){
   if(body.action==='line')row.lines[index]={number:this.normalizeLine(body.number),carrier:this.normalizeCarrier(body.provider),ivrLanguage:'ar',planGb:null};else row.lines.splice(index,1);
   row.landline=row.lines[0]?.number;if(row.lines[0]?.planGb)row.planGb=row.lines[0].planGb;else delete row.planGb;delete row.internetSetup;delete row.consentedAt;delete row.consentPolicy;row.savedAt=this.now();this.requests.save(s);
  }
  if(body.action==='check'||body.action==='schedule'){
   if(body.action==='schedule'&&!body.enabled){if(line.schedule)line.schedule.enabled=false;this.requests.save(s);}
   else{
    // Explicit admin confirmation records the existing disclosure, then existing
    // command logic performs all consent, duplicate, cooldown and schedule checks.
    row.noticePolicy=this.requests.policy();row.noticeProvider=this.requests.provider();row.noticeAt=this.now();this.requests.save(s);
    const before=row.lastJob;
    const answer=this.requests.handle(phone,(body.action==='check'?'Internet ':'Schedule ')+body.slot,{channel:body.channel});
    const after=this.requests.read().users?.[phone];
    if(body.action==='check')result=after?.lastJob&&after.lastJob!==before?'queued':'not_queued';
    else result=after?.lines?.[index]?.schedule?.enabled?'scheduled':'not_scheduled';
    if(typeof answer!=='string')result='unknown';
   }
  }
  ledger[body.request_id].result=result;this.saveLedger(ledger);return {...this.view(phone),operation:result};
 }
 audio(phone,event){this.phone(phone);if(!EVENT.test(event))throw new TrackerError('Recording not found',404);
  const matches=this.jobs(phone).filter(j=>this.result(j)?.eventId===event);if(matches.length!==1)throw new TrackerError('Recording not found',404);
  const recording=this.recording(matches[0],this.result(matches[0]));if(!recording)throw new TrackerError('Recording expired',410);return recording;
 }
 async route(req,reply,res){
  if(req.url==='/internet/contacts'){
   if(req.method!=='GET'){reply(405,{error:'Read only'});return true;}
   try{reply(200,this.directory());}catch{reply(503,{error:'Contact list unavailable'});}return true;
  }
  if(!req.url?.startsWith('/internet/contact/'))return false;
  const match=/^\/internet\/contact\/([1-9][0-9]{7,14})(?:\/recordings\/([A-F0-9]{8}))?$/.exec(req.url);
  if(!match){reply(404,{error:'Not found'});return true;}
  try{
   if(match[2]){
    if(req.method!=='GET')throw new TrackerError('Read only',405);
    const a=this.audio(match[1],match[2]),fd=fs.openSync(a.file,fs.constants.O_RDONLY|fs.constants.O_NOFOLLOW);
    res.writeHead(200,{'Content-Type':'audio/wav','Content-Length':fs.fstatSync(fd).size,'Cache-Control':'no-store','X-Content-Type-Options':'nosniff','Content-Disposition':'attachment; filename="'+match[2]+'.wav"'});
    const stream=fs.createReadStream(a.file,{fd,autoClose:true});stream.on('error',()=>res.destroy());res.on('close',()=>stream.destroy());stream.pipe(res);return true;
   }
   if(req.method==='GET')reply(200,this.view(match[1]));
   else if(req.method==='POST'){
    let raw='';for await(const chunk of req){raw+=chunk;if(Buffer.byteLength(raw)>4096)throw new TrackerError('Request too large',413);}
    let body;try{body=JSON.parse(raw);}catch{throw new TrackerError('Invalid request');}
    reply(200,this.mutate(match[1],body));
   }else throw new TrackerError('Method unavailable',405);
  }catch(error){reply(error instanceof TrackerError?error.status:503,{error:error instanceof TrackerError?error.message:'Internet tracker unavailable'});}
  return true;
 }
}
