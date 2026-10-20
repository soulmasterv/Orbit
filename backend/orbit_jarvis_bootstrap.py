"""Optional Flask integration. Imports do not read credentials or start services."""
import base64
import hashlib
import hmac
import http.client
from http.cookies import SimpleCookie
import json
import os
from pathlib import Path
import re
import secrets
import stat
import threading
import time
import urllib.error
import urllib.request
import uuid
from concurrent.futures import ThreadPoolExecutor

ORIGIN = 'https://jarvis.labbing.space'
PRIVATE = 'http://127.0.0.1:18082/session'
CONFIG = Path.home() / '.config/orbit-jarvis/bootstrap.json'

class Failure(Exception):
    def __init__(self, status=503, code='prerequisite_unavailable'):
        self.status, self.code = status, code

def protected_file(path):
    path = Path(path)
    if path.is_symlink() or not path.is_file():
        raise Failure()
    for candidate in (path, path.parent):
        st = candidate.stat()
        if st.st_uid != os.geteuid() or stat.S_IMODE(st.st_mode) & 0o077:
            raise Failure()
    return path.read_text(encoding='utf8')

def load_config():
    try:
        cfg = json.loads(protected_file(CONFIG))
        if cfg.get('enabled') is not True:
            raise Failure()
        if not all(isinstance(cfg.get(k), str) and cfg[k] and '\n' not in cfg[k] and '\r' not in cfg[k] for k in ('cf_client_id', 'cf_client_secret', 'bridge_key_file')):
            raise Failure()
        if not isinstance(cfg.get('cf_token_expires_at'), int):
            raise Failure()
        cfg['bridge_key'] = protected_file(cfg['bridge_key_file']).strip()
        if not re.fullmatch('[a-f0-9]{64}', cfg['bridge_key']):
            raise Failure()
        return cfg
    except Failure:
        raise
    except Exception:
        raise Failure() from None

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None

class Transport:
    def __init__(self):
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    def fetch(self, url, method='GET', headers=None, body=None):
        # All destinations are fixed in this module, never supplied by clients.
        if url != PRIVATE and not url.startswith(ORIGIN+'/'):
            raise Failure()
        headers = dict(headers or {})
        headers.setdefault('User-Agent', 'Orbit-JARVIS-Broker/1.0')
        req = urllib.request.Request(url, data=body, headers=headers, method=method)
        try:
            with self.opener.open(req, timeout=8) as res:
                payload=res.read(200001)
                if len(payload)>200000: raise Failure()
                return res.status, res.headers, payload
        except urllib.error.HTTPError as e:
            # Do not read/log upstream bodies or redirect URLs.
            if url==ORIGIN+'/memory' and e.code==404: return 404,e.headers,b''
            if url==PRIVATE and e.code in (409,429): raise Failure(e.code,'session_limit' if e.code==409 else 'issuance_throttled') from None
            raise Failure() from None
        except Exception:
            raise Failure() from None
    def websocket(self, cookie):
        conn=http.client.HTTPSConnection('jarvis.labbing.space',timeout=8)
        try:
            key=base64.b64encode(secrets.token_bytes(16)).decode()
            conn.request('GET','/voice',headers={'User-Agent':'Orbit-JARVIS-Broker/1.0','Origin':ORIGIN,'Cookie':cookie,'Connection':'Upgrade','Upgrade':'websocket','Sec-WebSocket-Version':'13','Sec-WebSocket-Key':key})
            res=conn.getresponse()
            expected=base64.b64encode(hashlib.sha1((key+'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
            if res.status==429: raise Failure(409,'session_limit')
            if res.status!=101 or res.getheader('Upgrade','').lower()!='websocket' or res.getheader('Sec-WebSocket-Accept')!=expected:
                raise Failure()
            # Never send audio or first-CSRF message. Closing releases the test lease.
        except Failure: raise
        except Exception: raise Failure() from None
        finally: conn.close()

def cookie_contract(name, value, expiry):
    return dict(name=name,value=value,domain='jarvis.labbing.space',path='/',secure=True,http_only=True,same_site='Strict',expires_at=expiry)

class Broker:
    def __init__(self, owner_token, config=load_config, transport=None, clock=time.time):
        self.owner_digest=hashlib.sha256(('Bearer '+owner_token).encode()).digest()
        self.config,self.transport,self.clock=config,transport or Transport(),clock
        self.lock=threading.Lock();self.nonces={};self.attempts=[]
    def handle(self, authorization, body, revoke=False):
        if not isinstance(authorization,str) or not hmac.compare_digest(hashlib.sha256(authorization.encode()).digest(),self.owner_digest):
            raise Failure(401,'unauthorized')
        if not isinstance(body,dict) or type(body.get('version')) is not int or body.get('version')!=1: raise Failure(400,'invalid_request')
        installation=body.get('installation_id');nonce=body.get('nonce')
        try:
            if not isinstance(installation,str) or str(uuid.UUID(installation))!=installation: raise ValueError()
        except Exception: raise Failure(400,'invalid_request') from None
        if not isinstance(nonce,str) or not re.fullmatch('[A-Za-z0-9_-]{22,128}',nonce): raise Failure(400,'invalid_request')
        now=int(self.clock())
        with self.lock:
            self.nonces={n:e for n,e in self.nonces.items() if e>now}
            self.attempts=[t for t in self.attempts if t>now-60]
            if nonce in self.nonces: raise Failure(409,'nonce_reused')
            if len(self.attempts)>=6: raise Failure(429,'issuance_throttled')
            self.attempts.append(now);self.nonces[nonce]=now+900
            cfg=self.config()
            payload={'version':1,'installation_id':installation.lower(),'nonce':nonce}
            if revoke:
                self.private(cfg,'DELETE',payload)
                return dict(version=1,nonce=nonce,revoked=True)
            if cfg['cf_token_expires_at']<=now+60:raise Failure()
            issued=False
            try:
                # Machine headers go ONLY to the fixed Access-protected origin.
                status,headers,_=self.transport.fetch(ORIGIN+'/',headers={'CF-Access-Client-Id':cfg['cf_client_id'],'CF-Access-Client-Secret':cfg['cf_client_secret']})
                if status!=200: raise Failure()
                raw_cookies=headers.get_all('Set-Cookie') or []
                cookies=SimpleCookie()
                for raw in raw_cookies: cookies.load(raw)
                auth=cookies.get('CF_Authorization')
                if not auth or auth['path'] not in ('','/') or auth['domain'].lstrip('.') not in ('','jarvis.labbing.space'): raise Failure()
                try:
                    part=auth.value.split('.')[1];claims=json.loads(base64.urlsafe_b64decode(part+'='*((-len(part))%4)))
                    expiry=claims['exp']
                    cookie_now=int(self.clock())
                    if type(expiry)!=int or not cookie_now+60<expiry<=cookie_now+900: raise ValueError()
                except Exception: raise Failure() from None
                # Parsing exp is only a lifetime bound, NOT JWT verification. Live Access requests below prove authorization.
                allow=('CF_Authorization','CF_Binding','CF_AppSession')
                selected=[]
                for name in allow:
                    if name in cookies:
                        item=cookies[name]
                        if item['domain'].lstrip('.') not in ('','jarvis.labbing.space') or item['path'] not in ('','/') or not re.fullmatch('[A-Za-z0-9_.~%+=/-]{1,12000}',item.value): raise Failure()
                        selected.append(cookie_contract(name,item.value,expiry))
                cookie='; '.join(x['name']+'='+x['value'] for x in selected)
                # These proof requests carry cookies ONLY, never service-token headers.
                def prove_asset(path):
                    status,h,_=self.transport.fetch(ORIGIN+path,headers={'Cookie':cookie})
                    kind=h.get('Content-Type','').split(';')[0].lower()
                    expected=('text/html',) if path=='/' else ('text/javascript','application/javascript')
                    if status!=200 or kind not in expected: raise Failure()
                with ThreadPoolExecutor(max_workers=4) as proofs:
                    list(proofs.map(prove_asset, ('/','/app.js','/capture.js','/memory.js')))
                result=self.private(cfg,'POST',payload);issued=True
                jarvis=result.get('cookie',{})
                if result.get('version')!=1 or result.get('nonce')!=nonce or result.get('entry_url')!=ORIGIN+'/' or jarvis.get('name')!='jarvis' or jarvis.get('domain')!='jarvis.labbing.space' or jarvis.get('path')!='/' or jarvis.get('secure') is not True or jarvis.get('http_only') is not True or not re.fullmatch('[a-f0-9]{64}',jarvis.get('value','')):
                    raise Failure()
                jarvis_exp=result.get('expires_at')
                issuer_now=int(self.clock())
                if type(jarvis_exp)!=int or not issuer_now+60<jarvis_exp<=issuer_now+900: raise Failure()
                expiry=min(expiry,jarvis_exp,cfg['cf_token_expires_at']);cookie+='; jarvis='+jarvis['value']
                status,h,raw=self.transport.fetch(ORIGIN+'/session',headers={'Cookie':cookie})
                if status!=200 or not isinstance(json.loads(raw).get('csrf'),str): raise Failure()
                status,_,_=self.transport.fetch(ORIGIN+'/memory',headers={'Cookie':cookie})
                # Current server has no memory handler: explicitly report that capability gap.
                # Authentication failures and all other unexpected statuses still fail closed.
                if status not in (200,404): raise Failure()
                memory_available=status==200
                self.transport.websocket(cookie)
                if expiry<=int(self.clock())+60: raise Failure()
                for item in selected:item['expires_at']=expiry
                selected.append(cookie_contract('jarvis',jarvis['value'],expiry))
                return dict(version=1,nonce=nonce,entry_url=ORIGIN+'/',expires_at=expiry,cookies=selected,memory_available=memory_available)
            except Exception as error:
                if issued:
                    try:self.private(cfg,'DELETE',dict(payload,nonce=secrets.token_urlsafe(24)))
                    except Exception:pass
                if isinstance(error,Failure):raise
                raise Failure() from None
    def private(self,cfg,method,payload):
        status,_,raw=self.transport.fetch(PRIVATE,method=method,headers={'Authorization':'Bearer '+cfg['bridge_key'],'Content-Type':'application/json'},body=json.dumps(payload).encode())
        if status!=200:raise Failure(status if status in (409,429) else 503)
        return json.loads(raw)

def register(app, owner_token):
    from flask import jsonify, request
    broker=Broker(owner_token)
    def endpoint(revoke=False):
        try:
            # Native URLSession does not need browser CORS or an Origin exception.
            if request.headers.get('Origin'): raise Failure(403,'owner_not_permitted')
            if request.content_length is None or request.content_length>2048: raise Failure(400,'invalid_request')
            result=broker.handle(request.headers.get('Authorization',''),request.get_json(silent=True),revoke)
            response=jsonify(result);response.headers['Cache-Control']='no-store';return response
        except Failure as error:
            response=jsonify(error=error.code);response.status_code=error.status;response.headers['Cache-Control']='no-store';return response
        except Exception:
            response=jsonify(error='prerequisite_unavailable');response.status_code=503;response.headers['Cache-Control']='no-store';return response
    app.add_url_rule('/api/jarvis/app-session','jarvis_app_session',lambda:endpoint(False),methods=['POST'])
    app.add_url_rule('/api/jarvis/app-session/revoke','jarvis_app_session_revoke',lambda:endpoint(True),methods=['POST'])
