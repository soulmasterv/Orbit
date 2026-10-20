import crypto from 'node:crypto';
const uuid=/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i;
export function appSessionHandler({secret,origin,sessions,clients,pool,now=()=>Date.now()}){
  if(!/^[a-f0-9]{64}$/.test(secret)||!origin.startsWith('https://'))throw Error('Invalid private app-session configuration');
  const attempts=[],nonces=new Map();
  const key=crypto.createHash('sha256').update('Bearer '+secret).digest();
  const revoke=device=>{for(const [token,s] of sessions)if(s.appDevice===device){sessions.delete(token);clients.get(token)?.close(1000,'App session revoked');}};
  return async(req,res)=>{
    const reply=(status,data)=>{res.writeHead(status,{'Content-Type':'application/json','Cache-Control':'no-store'});res.end(JSON.stringify(data));};
    const supplied=crypto.createHash('sha256').update(req.headers.authorization||'').digest();
    if(!crypto.timingSafeEqual(supplied,key))return reply(401,{error:'unauthorized'});
    if(req.url!=='/session'||!['POST','DELETE'].includes(req.method))return reply(404,{error:'not_found'});
    try{
      let raw='';for await(const chunk of req){raw+=chunk;if(Buffer.byteLength(raw)>2048)return reply(400,{error:'invalid_request'});}
      let body;try{body=JSON.parse(raw);}catch{return reply(400,{error:'invalid_request'});}
      if(body?.version!==1||!uuid.test(body.installation_id||'')||typeof body.nonce!=='string'||!/^[A-Za-z0-9_-]{22,128}$/.test(body.nonce))return reply(400,{error:'invalid_request'});
      const time=now();for(const [n,expiry]of nonces)if(expiry<=time)nonces.delete(n);
      if(nonces.has(body.nonce))return reply(409,{error:'nonce_reused'});
      while(attempts.length&&attempts[0]<=time-60000)attempts.shift();
      if(attempts.length>=12)return reply(429,{error:'issuance_throttled'});attempts.push(time);nonces.set(body.nonce,time+900000);
      const device=body.installation_id.toLowerCase();
      if(req.method==='DELETE'){revoke(device);return reply(200,{version:1,nonce:body.nonce,revoked:true});}
      for(const [token,s]of sessions)if(s.expires<=time)sessions.delete(token);
      if(sessions.size>=100||pool.active.size>=pool.limits.concurrent)return reply(409,{error:'session_limit'});
      const devices=new Set([...sessions.values()].map(s=>s.appDevice).filter(Boolean));
      if(devices.size>=10&&!devices.has(device))return reply(409,{error:'device_limit'});
      revoke(device);
      const token=crypto.randomBytes(32).toString('hex'),expires=time+900000;
      sessions.set(token,{csrf:crypto.randomBytes(24).toString('hex'),expires,appDevice:device});
      return reply(200,{version:1,nonce:body.nonce,entry_url:origin+'/',expires_at:Math.floor(expires/1000),cookie:{name:'jarvis',value:token,domain:new URL(origin).hostname,path:'/',secure:true,http_only:true,same_site:'Strict',expires_at:Math.floor(expires/1000)}});
    }catch{return reply(503,{error:'prerequisite_unavailable'});}
  };
}
