"""Orbit owner-only phone pilot. No arbitrary commands, no automatic call or SMS sends."""
import functools, hashlib, hmac, json, os, sqlite3, subprocess, threading, time, uuid
from pathlib import Path

HOME=Path.home()
BROKER_DB=HOME/'jarvis-phone-integration/phone-alerts.db'
OPS_DB=HOME/'jarvis-phone-integration/orbit-phone-pilot.db'
LOCK=threading.RLock()
CACHE={}
PM2={'answering':'jarvis-phone-worker','outgoing':'jarvis-outgoing','bluetooth':'jarvis-bluetooth-watch'}
UNIT='jarvis-auto-answer.service'
def db():
    c=sqlite3.connect(BROKER_DB,timeout=5);c.row_factory=sqlite3.Row;return c

def meta(c,k,default=None):
    r=c.execute('SELECT value FROM alert_meta WHERE id=?',(k,)).fetchone()
    return json.loads(r[0]) if r else default

def put(c,k,v):
    c.execute('INSERT INTO alert_meta VALUES (?,?) ON CONFLICT(id) DO UPDATE SET value=excluded.value',(k,json.dumps(v)))

def reconcile(c,mode,revision,forward):
    """Called within broker transaction. New server settings win until acknowledged."""
    ctl=meta(c,'orbit_phone_control')
    if not ctl and not (type(revision) is int and type(forward) is bool):
        return {'revision':0,'mode':mode if mode in ('sms','web','whatsapp') else 'web','forward_enabled':False,'updated_at':0}
    if not ctl:
        ctl={'revision':1,'mode':mode if mode in ('sms','web','whatsapp') else 'web','forward_enabled':forward is True,'updated_at':time.time()}
        put(c,'orbit_phone_control',ctl)
    if type(revision) is int and revision==ctl['revision']:
        put(c,'orbit_phone_ack',revision)
        if mode in ('sms','web','whatsapp') and type(forward) is bool and (mode!=ctl['mode'] or forward!=ctl['forward_enabled']):
            ctl=dict(ctl,revision=ctl['revision']+1,mode=mode,forward_enabled=forward,updated_at=time.time())
            put(c,'orbit_phone_control',ctl)
    return ctl

def run(args,timeout=4):
    return subprocess.run(args,capture_output=True,text=True,timeout=timeout)

def runtime():
    with LOCK:
        if CACHE.get('until',0)>time.time():return CACHE['value']
        result={'adb':'unknown','bluetooth':'unknown','battery':None,'workers':{}}
        try:
            serial=(HOME/'jarvis-phone-integration/adb-serial').read_text().strip()
            if serial and len(serial)<128:
                result['adb']='connected' if run(['adb','-s',serial,'get-state'],2).stdout.strip()=='device' else 'disconnected'
                if result['adb']=='connected':
                    import re
                    b=run(['adb','-s',serial,'shell','dumpsys','battery'],2)
                    m=re.search(r'^\s*level:\s*(\d+)\s*$',b.stdout,re.M)
                    if m:result['battery']=max(0,min(100,int(m[1])))
        except Exception:pass
        try:
            p=run(['bluetoothctl','info','CC:46:4E:77:75:95'],2)
            result['bluetooth']='connected' if 'Connected: yes' in p.stdout else 'disconnected'
        except Exception:pass
        try:
            for p in json.loads(run(['pm2','jlist'],3).stdout):
                if p.get('name') in PM2.values():result['workers'][p['name']]=p.get('pm2_env',{}).get('status','unknown')
        except Exception:pass
        try:result['auto_answer']=run(['systemctl','--user','is-active',UNIT],2).stdout.strip()
        except Exception:result['auto_answer']='unknown'
        CACHE.update(until=time.time()+10,value=result)
        return result

def snapshot():
    with db() as c:
        last=meta(c,'last_phone',0);health=meta(c,'health',{})
        ctl=meta(c,'orbit_phone_control',{'revision':0,'mode':meta(c,'notification_mode','web'),'forward_enabled':False,'updated_at':0})
        ack=meta(c,'orbit_phone_ack',0)
    return {'version':1,'at':time.time(),'phone_seen_seconds':round(time.time()-last) if last else None,
      'health':health,'settings':ctl,'settings_applied':bool(ctl['revision'] and ack==ctl['revision']),'runtime':runtime()}

def idle():
    import re
    serial=(HOME/'jarvis-phone-integration/adb-serial').read_text().strip()
    p=run(['adb','-s',serial,'shell','dumpsys','telephony.registry'],4)
    states=re.findall(r'^\s*mCallState=([012])\s*$',p.stdout,re.M)
    return p.returncode==0 and bool(states) and all(s=='0' for s in states)

def operations():
    c=sqlite3.connect(OPS_DB,timeout=5)
    c.execute('CREATE TABLE IF NOT EXISTS operations (id TEXT PRIMARY KEY,hash TEXT NOT NULL,result TEXT NOT NULL,created REAL NOT NULL)')
    c.commit();os.chmod(OPS_DB,0o600);return c

def register(app,token):
    global request, jsonify
    from flask import request, jsonify
    def auth(fn):
        @functools.wraps(fn)
        def wrapped(*a,**kw):
            if not hmac.compare_digest(request.headers.get('Authorization',''), 'Bearer '+token):return jsonify(error='unauthorized'),401
            if request.method!='GET' and request.headers.get('Origin'):return jsonify(error='native_client_required'),403
            if request.content_length and request.content_length>2048:return jsonify(error='too_large'),413
            out=fn(*a,**kw)
            return out
        return wrapped
    @app.after_request
    def phone_no_store(response):
        if request.path.startswith('/api/jarvis-phone/'):
            response.headers['Cache-Control']='no-store';response.headers['X-Content-Type-Options']='nosniff'
        return response
    @app.get('/api/jarvis-phone/status')
    @auth
    def phone_status():return jsonify(snapshot())
    @app.post('/api/jarvis-phone/commands')
    @auth
    def phone_command():
        raw=request.stream.read(2049)
        if len(raw)>2048:return jsonify(error='too_large'),413
        try:body=json.loads(raw)
        except (ValueError,UnicodeDecodeError):return jsonify(error='invalid_request'),422
        if not isinstance(body,dict):return jsonify(error='invalid_request'),422
        ident=body.get('request_id')
        try:
            if str(uuid.UUID(ident))!=ident:raise ValueError()
        except (ValueError,TypeError,AttributeError):return jsonify(error='invalid_request_id'),422
        kind=body.get('kind')
        if kind=='settings':
            if set(body)!={'request_id','kind','revision','mode','forward_enabled'} or type(body['revision']) is not int or type(body['forward_enabled']) is not bool or body['mode'] not in ('sms','web','whatsapp'):return jsonify(error='invalid_settings'),422
        elif kind=='automation':
            if set(body)!={'request_id','kind','target','enabled'} or body['target'] not in ('answering','outgoing','bluetooth','all') or type(body['enabled']) is not bool:return jsonify(error='invalid_action'),422
        else:return jsonify(error='unsupported_command'),422
        fingerprint=hashlib.sha256(json.dumps(body,sort_keys=True).encode()).hexdigest()
        with LOCK, operations() as ops:
            ops.execute('BEGIN IMMEDIATE')
            old=ops.execute('SELECT hash,result FROM operations WHERE id=?',(ident,)).fetchone()
            if old:return (jsonify(json.loads(old[1])),200) if old[0]==fingerprint else (jsonify(error='request_id_conflict'),409)
            if ops.execute('SELECT count(*) FROM operations').fetchone()[0]>=10000:return jsonify(error='operation_history_full'),503
            if kind=='settings':
                with db() as c:
                    c.execute('BEGIN IMMEDIATE');prior=meta(c,'orbit_phone_control',{'revision':0})
                    if prior['revision']!=body['revision']:return jsonify(error='settings_changed_refresh'),409
                    ctl={'revision':prior['revision']+1,'mode':body['mode'],'forward_enabled':body['forward_enabled'],'updated_at':time.time()}
                    put(c,'orbit_phone_control',ctl);put(c,'notification_mode',ctl['mode'])
                    if ctl['mode']!='sms':c.execute("UPDATE alert_events SET sms='web_only' WHERE sms='pending' AND dispatched IS NULL")
                result={'request_id':ident,'status':'pending_phone','revision':ctl['revision']}
                ops.execute('INSERT INTO operations VALUES (?,?,?,?)',(ident,fingerprint,json.dumps(result),time.time()));ops.commit()
                return jsonify(result)
            try:
                if not idle():return jsonify(error='phone_busy_or_state_unavailable'),409
            except Exception:return jsonify(error='phone_state_unavailable'),409
            result={'request_id':ident,'status':'unknown','message':'Check status before retrying.'}
            ops.execute('INSERT INTO operations VALUES (?,?,?,?)',(ident,fingerprint,json.dumps(result),time.time()));ops.commit()
            names=list(PM2) if body['target']=='all' else [body['target']]
            failures=[]
            for name in names:
                try:
                    p=run(['pm2','start' if body['enabled'] else 'stop',PM2[name]],4)
                    if p.returncode:failures.append(name)
                    if name=='answering':
                        p=run(['systemctl','--user','start' if body['enabled'] else 'stop',UNIT],4)
                        if p.returncode:failures.append('auto_answer')
                except Exception:failures.append(name)
            if body['target']=='all' and not body['enabled']:
                with db() as c:
                    c.execute('BEGIN IMMEDIATE');ctl=meta(c,'orbit_phone_control',{'revision':0,'mode':'web'})
                    ctl=dict(ctl,revision=ctl['revision']+1,forward_enabled=False,mode='web',updated_at=time.time())
                    put(c,'orbit_phone_control',ctl);put(c,'notification_mode','web')
                    c.execute("UPDATE alert_events SET sms='web_only' WHERE sms='pending' AND dispatched IS NULL")
            CACHE.clear()
            result=dict(result,status='failed' if failures else 'applied',failed_components=failures)
            ops.execute('UPDATE operations SET result=? WHERE id=?',(json.dumps(result),ident));ops.commit()
            return jsonify(result)
