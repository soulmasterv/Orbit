"""Orbit owner-only phone pilot. No arbitrary commands, no automatic call or SMS sends."""
import functools, hashlib, hmac, json, os, sqlite3, subprocess, threading, time, uuid
from pathlib import Path
import phone_controls as controls

HOME=Path.home()
BROKER_DB=HOME/'jarvis-phone-integration/phone-alerts.db'
OPS_DB=HOME/'jarvis-phone-integration/orbit-phone-pilot.db'
LOCK=threading.RLock()
CACHE={}
PM2={'answering':'jarvis-phone-worker','outgoing':'jarvis-outgoing','bluetooth':'jarvis-bluetooth-watch'}
UNIT='jarvis-auto-answer.service'
PHONE_BLUETOOTH_ADDRESS = 'CC:46:4E:77:75:95'
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
            p=run(['bluetoothctl','info',PHONE_BLUETOOTH_ADDRESS],2)
            result['bluetooth']='connected' if 'Connected: yes' in p.stdout else 'disconnected'
        except Exception:pass
        try:
            for p in json.loads(run(['pm2','jlist'],3).stdout):
                if p.get('name') in PM2.values():result['workers'][p['name']]=p.get('pm2_env',{}).get('status','unknown')
        except Exception:pass
        try:result['auto_answer']=run(['systemctl','--user','is-active',UNIT],2).stdout.strip()
        except Exception:result['auto_answer']='unknown'
        result['checked_at'] = time.time()
        CACHE.update(until=time.time()+10,value=result)
        return result

def snapshot():
    with db() as c:
        last=meta(c,'last_phone',0);health=meta(c,'health',{})
        ctl=meta(c,'orbit_phone_control',{'revision':0,'mode':meta(c,'notification_mode','web'),'forward_enabled':False,'updated_at':0})
        ack=meta(c,'orbit_phone_ack',0)
    with operations() as ops, db() as broker:
        recent = []
        for ident, payload, created in ops.execute(
            'SELECT id,result,created FROM operations ORDER BY created DESC LIMIT 10'
        ):
            result = json.loads(payload)
            status = result.get('status', 'unknown')
            revision = result.get('revision')
            kind = result.get('kind', 'settings' if revision is not None else 'automation')
            if kind == 'settings' and status == 'pending_phone' and revision == ack:
                status = 'phone_confirmed'
            if kind == 'test_notification':
                event = broker.execute(
                    'SELECT kind,sms,push,expires FROM alert_events WHERE id=?', (ident,)
                ).fetchone()
                if event:
                    status = event['sms'] if event['kind'] == 'orbit_test_sms' else event['push']
                    if status in ('pending', 'sending') and event['expires'] <= time.time():
                        status = 'expired'
            recent.append({'id': ident, 'kind': kind, 'status': status, 'at': created})
    return {'version':1,'at':time.time(),'phone_seen_seconds':round(time.time()-last) if last else None,
      'phone_last_seen_at': last or None, 'recent_activity': recent,
      'answering_pause_supported': controls.capability('answering_pause'),
      'answering_pause': controls.read_pause(),
      'queue_supported': controls.capability('call_queue'),
      'bluetooth_reconnect_supported': True,
      'test_channels': {
          'web': 'Paired web subscription' if controls.capability('test_web') else None,
          'sms': controls.destination('sms') if controls.capability('test_sms') else None,
          'whatsapp': controls.destination('whatsapp') if controls.capability('test_whatsapp') else None,
      },
      'health':health,'settings':ctl,'settings_applied':bool(ctl['revision'] and ack==ctl['revision']),'runtime':runtime()}

def idle():
    import re
    serial=(HOME/'jarvis-phone-integration/adb-serial').read_text().strip()
    p=run(['adb','-s',serial,'shell','dumpsys','telephony.registry'],4)
    states=re.findall(r'^\s*mCallState=([012])\s*$',p.stdout,re.M)
    return p.returncode==0 and bool(states) and all(s=='0' for s in states)

def reconnect_bluetooth():
    info = run(['bluetoothctl', 'info', PHONE_BLUETOOTH_ADDRESS], 2)
    if info.returncode or 'Paired: yes' not in info.stdout:
        return 'failed'
    if 'Connected: yes' in info.stdout:
        return 'applied'
    if not idle():
        return 'failed'
    path = '/org/bluez/hci0/dev_' + PHONE_BLUETOOTH_ADDRESS.replace(':', '_')
    result = run([
        'busctl', '--system', 'call', 'org.bluez', path, 'org.bluez.Device1',
        'ConnectProfile', 's', '0000111f-0000-1000-8000-00805f9b34fb'
    ], 8)
    return 'applied' if result.returncode == 0 else 'failed'

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
    @app.get('/api/jarvis-phone/queue')
    @auth
    def phone_queue():
        if not controls.capability('call_queue'):
            return jsonify(error='queue_unavailable'), 503
        try:
            status, data = controls.call_queue()
            if status == 200:
                return jsonify(jobs=data['jobs'])
        except Exception:
            pass
        return jsonify(error='queue_unavailable'), 503
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
        elif kind == 'reconnect_bluetooth':
            if set(body) != {'request_id', 'kind'}:
                return jsonify(error='invalid_action'), 422
        elif kind == 'answering_pause':
            if set(body) != {'request_id', 'kind', 'minutes'} or type(body['minutes']) is not int or body['minutes'] not in (-1, 0, 30, 60):
                return jsonify(error='invalid_action'), 422
            if not controls.capability('answering_pause'):
                return jsonify(error='answering_pause_unavailable'), 503
        elif kind == 'cancel_call':
            if set(body) != {'request_id', 'kind', 'job_id'} or not isinstance(body['job_id'], str) or not 1 <= len(body['job_id']) <= 64:
                return jsonify(error='invalid_action'), 422
            if not controls.capability('call_queue'):
                return jsonify(error='queue_unavailable'), 503
        elif kind == 'test_notification':
            if set(body) != {'request_id', 'kind', 'channel', 'destination'} or body['channel'] not in ('web', 'sms', 'whatsapp'):
                return jsonify(error='invalid_action'), 422
            channel = body['channel']
            expected = 'Paired web subscription' if channel == 'web' else controls.destination(channel)
            if not controls.capability('test_' + channel) or not expected or body['destination'] != expected:
                return jsonify(error='destination_unavailable_or_changed'), 409
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
            if kind in ('automation', 'reconnect_bluetooth'):
                try:
                    if not idle():return jsonify(error='phone_busy_or_state_unavailable'),409
                except Exception:return jsonify(error='phone_state_unavailable'),409
            if kind == 'test_notification':
                if ops.execute("SELECT 1 FROM operations WHERE created>? AND json_extract(result,'$.kind')='test_notification' LIMIT 1", (time.time()-60,)).fetchone():
                    return jsonify(error='test_rate_limited'), 429
                if channel == 'sms':
                    with db() as c:
                        if time.time() - meta(c, 'last_phone', 0) > 20 or meta(c, 'notification_mode', 'web') != 'sms':
                            return jsonify(error='sms_companion_unavailable'), 409
            result={'request_id':ident,'status':'unknown','message':'Check status before retrying.'}
            result['kind'] = kind
            ops.execute('INSERT INTO operations VALUES (?,?,?,?)',(ident,fingerprint,json.dumps(result),time.time()));ops.commit()
            if kind != 'automation':
                try:
                    if kind == 'reconnect_bluetooth':
                        result['status'] = reconnect_bluetooth()
                    elif kind == 'answering_pause':
                        controls.set_pause(None if body['minutes'] == -1 else body['minutes'])
                        result['status'] = 'applied'
                    elif kind == 'cancel_call':
                        status, response = controls.call_queue(body['job_id'])
                        result['status'] = 'applied' if status == 200 and response.get('status') == 'cancelled' else 'failed'
                    elif kind == 'test_notification':
                        message = 'Orbit phone controls test notification.'
                        if channel == 'whatsapp':
                            result['status'] = controls.send_whatsapp(ident, message, expected)
                        else:
                            now = time.time()
                            with db() as c:
                                c.execute(
                                    'INSERT INTO alert_events(id,kind,body,created,expires,sms,push) VALUES (?,?,?,?,?,?,?)',
                                    (ident, 'orbit_test_' + channel, message, now, now + 60,
                                     'pending' if channel == 'sms' else 'web_only',
                                     'pending' if channel == 'web' else 'not_needed')
                                )
                            result['status'] = 'pending_phone' if channel == 'sms' else 'queued'
                except Exception:
                    pass
                CACHE.clear()
                ops.execute('UPDATE operations SET result=? WHERE id=?',(json.dumps(result),ident))
                return jsonify(result)
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
            if body['enabled'] and body['target'] in ('answering', 'all') and not failures:
                controls.set_pause(0)
            CACHE.clear()
            result=dict(result,status='failed' if failures else 'applied',failed_components=failures)
            ops.execute('UPDATE operations SET result=? WHERE id=?',(json.dumps(result),ident));ops.commit()
            return jsonify(result)
