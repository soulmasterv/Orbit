"""Owner-only, one-recipient Classera plaintext. No automatic mutation retries."""
import hashlib,hmac,json,re,sqlite3,time,uuid
from datetime import datetime,timezone
from pathlib import Path
import requests
from flask import jsonify,request
from classera_monitoring_api import read_env

class MessageProblem(Exception):
    def __init__(self,code,status=503):self.code,self.status=code,status

class Kapso:
    def __init__(self,http=None):
        self.http=http or requests.Session()
    def settings(self,klass):
        number={"12F":"1","12E":"2"}.get(klass)
        if not number:raise MessageProblem("invalid_class",422)
        config=read_env(Path("/home/local/classera")/("classera-"+number)/".env")
        shared=read_env(Path("/home/local/classera/shared/kapso.env"))
        if config.get("WHATSAPP_PROVIDER")!="kapso" or config.get("CLASSERA_CLASS")!=klass:
            raise MessageProblem("provider_unavailable")
        key,identifier=shared.get("KAPSO_API_KEY"),shared.get("KAPSO_PHONE_NUMBER_ID")
        if not key or not identifier or not re.fullmatch(r"[0-9]+",identifier):raise MessageProblem("provider_unavailable")
        return key,identifier
    def window(self,phone,klass):
        key,identifier=self.settings(klass)
        rows=[];after=None
        for page in range(5):
            params={"phone_number":phone,"limit":100,"fields":"kapso(last_inbound_at)"}
            if after:params["after"]=after
            try:
                response=self.http.get("https://api.kapso.ai/meta/whatsapp/v24.0/"+identifier+"/conversations",
                    headers={"X-API-Key":key},params=params,timeout=10,allow_redirects=False)
                if response.status_code!=200:raise MessageProblem("window_unavailable")
                body=response.json()
                if not isinstance(body,dict) or not isinstance(body.get("data"),list):raise MessageProblem("window_unavailable")
                rows.extend(body["data"])
                paging=body.get("paging") or {}
                if not paging.get("next"):break
                cursor=(paging.get("cursors") or {}).get("after")
                if not isinstance(cursor,str) or not cursor or cursor==after:raise MessageProblem("window_unavailable")
                after=cursor
            except (requests.RequestException,ValueError,TypeError):raise MessageProblem("window_unavailable")
        else:raise MessageProblem("window_unavailable")
        now=int(time.time());times=[]
        for row in rows:
            if not isinstance(row,dict):raise MessageProblem("window_unavailable")
            if str(row.get("phone_number","")).lstrip("+")!=phone or str(row.get("phone_number_id",""))!=identifier:continue
            raw=(row.get("kapso") or {}).get("last_inbound_at")
            if not raw:continue
            try:
                value=datetime.fromisoformat(str(raw).replace("Z","+00:00"))
                if value.tzinfo is None:raise ValueError()
                value=int(value.timestamp())
                if value>now:raise ValueError()
                times.append(value)
            except (ValueError,TypeError,OverflowError):raise MessageProblem("window_unavailable")
        inbound=max(times) if times else None
        seconds=max(0,min(86400,inbound+86400-now)) if inbound else None
        return {"class_name":klass,"window_open":seconds>0 if seconds is not None else None,
                "seconds_left":seconds,"last_inbound_at":inbound}
    def send(self,phone,klass,text):
        key,identifier=self.settings(klass)
        response=self.http.post("https://api.kapso.ai/meta/whatsapp/v24.0/"+identifier+"/messages",
            headers={"X-API-Key":key,"Content-Type":"application/json"},
            json={"messaging_product":"whatsapp","recipient_type":"individual","to":phone,
                  "type":"text","text":{"body":text,"preview_url":False}},
            timeout=15,allow_redirects=False)
        if 400<=response.status_code<500:return "failed",None
        if not 200<=response.status_code<300:return "unknown",None
        try:
            identifier=response.json()["messages"][0]["id"]
            if isinstance(identifier,str) and identifier:return "accepted",identifier
        except (KeyError,ValueError,TypeError,IndexError):pass
        return "unknown",None

class Messaging:
    def __init__(self,directory,provider=None):
        self.directory=directory;self.provider=provider or Kapso()
        with directory.connect() as c:
            c.execute("""CREATE TABLE IF NOT EXISTS orbit_classera_text_operations(
                id TEXT PRIMARY KEY,phone TEXT NOT NULL,class_name TEXT NOT NULL,
                body_hash TEXT NOT NULL,status TEXT NOT NULL,message_id TEXT,
                created_at INTEGER NOT NULL,updated_at INTEGER NOT NULL)""")
    def eligible(self,phone,klass):
        current=self.directory.get(phone)
        return current["activity_status"]=="allowed" and current["signup_session"] is None and any(
            row["class_name"]==klass and row["status"]=="active" for row in current["subscriptions"])
    def windows(self,phone):
        current=self.directory.get(phone);windows=[]
        for klass in ("12F","12E"):
            if any(row["class_name"]==klass for row in current["subscriptions"]):
                try:window=self.provider.window(phone,klass)
                except MessageProblem:window={"class_name":klass,"window_open":None,"seconds_left":None,"last_inbound_at":None}
                window["can_send_plaintext"]=bool(window["window_open"] and window["seconds_left"]>=30 and self.eligible(phone,klass))
                windows.append(window)
        return {"version":1,"phone":phone,"whatsapp_windows":windows,"updated_at":int(time.time())}
    def operation(self,phone,identifier):
        try:
            if str(uuid.UUID(identifier))!=identifier:raise ValueError()
        except (ValueError,TypeError):raise MessageProblem("invalid_request",422)
        with self.directory.connect() as c:
            row=c.execute("SELECT id,phone,class_name,status,message_id,created_at,updated_at FROM orbit_classera_text_operations WHERE id=? AND phone=?",(identifier,phone)).fetchone()
        if not row:raise MessageProblem("operation_not_found",404)
        result=dict(row);result["version"]=1
        if result["message_id"]:
            try:
                path=Path("/home/local/classera/shared/delivery_state.db").resolve().as_uri()+"?mode=ro"
                with sqlite3.connect(path,uri=True,timeout=2) as c:
                    states=[r[0] for r in c.execute("SELECT status FROM orbit_delivery_events WHERE message_id=?",(result["message_id"],))]
                for state in ("read","delivered","failed","sent"):
                    if state in states:result["status"]=state;break
            except (sqlite3.Error,OSError):pass
        return result
    def submit(self,phone,data):
        if not isinstance(data,dict) or set(data)!={"request_id","class_name","text"}:raise MessageProblem("invalid_request",422)
        identifier,klass,text=(data[k] for k in ("request_id","class_name","text"))
        try:
            if not isinstance(identifier,str) or str(uuid.UUID(identifier))!=identifier:raise ValueError()
        except (ValueError,TypeError,AttributeError):raise MessageProblem("invalid_request",422)
        if klass not in ("12F","12E") or not isinstance(text,str) or not text.strip() or len(text)>4096 or any(ord(c)<32 and c not in "\n\t" for c in text):
            raise MessageProblem("invalid_request",422)
        fingerprint=hashlib.sha256(json.dumps([phone,klass,text],ensure_ascii=False).encode()).hexdigest()
        with self.directory.connect() as c:
            old=c.execute("SELECT phone,body_hash FROM orbit_classera_text_operations WHERE id=?",(identifier,)).fetchone()
        if old:
            if old["phone"]!=phone or not hmac.compare_digest(old["body_hash"],fingerprint):raise MessageProblem("request_id_conflict",409)
            return self.operation(phone,identifier)
        if not self.eligible(phone,klass):raise MessageProblem("student_not_eligible",409)
        window=self.provider.window(phone,klass)
        if not window["window_open"] or (window["seconds_left"] or 0)<30:raise MessageProblem("window_closed",409)
        if not self.eligible(phone,klass):raise MessageProblem("student_not_eligible",409)
        now=int(time.time())
        with self.directory.connect() as c:
            c.execute("BEGIN IMMEDIATE")
            if c.execute("SELECT COUNT(*) FROM orbit_classera_text_operations WHERE created_at>?",(now-60,)).fetchone()[0]>=6:
                raise MessageProblem("issuance_throttled",429)
            old=c.execute("SELECT phone,body_hash FROM orbit_classera_text_operations WHERE id=?",(identifier,)).fetchone()
            if old:
                if old["phone"]!=phone or not hmac.compare_digest(old["body_hash"],fingerprint):raise MessageProblem("request_id_conflict",409)
            else:
                c.execute("INSERT INTO orbit_classera_text_operations VALUES(?,?,?,?,'reserved',NULL,?,?)",(identifier,phone,klass,fingerprint,now,now))
        if old:return self.operation(phone,identifier)
        status,message="unknown",None
        if not self.eligible(phone,klass):status="failed"
        else:
            try:status,message=self.provider.send(phone,klass,text)
            except Exception:pass
        with self.directory.connect() as c:
            c.execute("UPDATE orbit_classera_text_operations SET status=?,message_id=?,updated_at=? WHERE id=?",(status,message,int(time.time()),identifier))
        return self.operation(phone,identifier)

def register(app,owner_token,directory,provider=None):
    service=Messaging(directory,provider)
    def handle(phone,identifier=None):
        supplied=request.headers.get("Authorization","")
        if not owner_token or not hmac.compare_digest(supplied.encode(),("Bearer "+owner_token).encode()):return jsonify(error="unauthorized"),401
        if request.headers.get("Origin") or request.headers.get("Sec-Fetch-Site")=="cross-site":return jsonify(error="owner_not_permitted"),403
        try:
            from classera_students import phone_value
            try:phone_value(phone)
            except Exception:raise MessageProblem("invalid_request",422)
            if identifier:return jsonify(service.operation(phone,identifier)),200
            if request.method=="GET":return jsonify(service.windows(phone)),200
            if request.content_length is None or request.content_length>20000 or not request.is_json:raise MessageProblem("invalid_request",422)
            return jsonify(service.submit(phone,request.get_json(silent=True))),200
        except MessageProblem as e:return jsonify(error=e.code),e.status
        except (sqlite3.Error,OSError):return jsonify(error="messaging_unavailable"),503
        except Exception:return jsonify(error="messaging_unavailable"),503
    app.add_url_rule("/api/classera-students/<phone>/messaging","classera_messaging_windows",handle,methods=["GET","POST"])
    app.add_url_rule("/api/classera-students/<phone>/messaging/<identifier>","classera_messaging_operation",handle,methods=["GET"])
    return service
