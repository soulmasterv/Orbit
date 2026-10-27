"""Owner-only Classera monitoring/preview API. Sending is disabled without a verified adapter."""
from contextlib import contextmanager
import hashlib
import hmac
import json
import re
import sqlite3
import time
import uuid
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor
from flask import jsonify, request
from orbit_classera_monitor import Store, STATES

class Problem(Exception):
    def __init__(self, code, status=422): self.code,self.status=code,status

def read_env(path):
    # Never expose configuration values through responses.
    result={}
    try:
        for line in Path(path).read_text().splitlines():
            if line.strip() and not line.lstrip().startswith("#") and "=" in line:
                k,v=line.split("=",1);result[k.strip()]=v.strip().strip("'\"")
    except OSError: pass
    return result

class ClassReady:
    def __init__(self, store, catalog, sender=None):
        self.store,self.catalog,self.sender=store,catalog,sender
        self.pool=ThreadPoolExecutor(max_workers=1,thread_name_prefix="class-ready") if sender else None

    def _preview(self, conn, class_id):
        catalog=self.catalog();info=next((c for c in catalog if c["id"]==class_id),None)
        if info is None: raise Problem("class_not_found",404)
        rows=[dict(r) for r in conn.execute("""SELECT s.phone,s.name,s.class_name,s.joined_at,s.updated_at,
          COALESCE(c.activity_status,'allowed') AS activity_status,
          EXISTS(SELECT 1 FROM people.signup_sessions p WHERE p.phone=s.phone) AS signup
          FROM people.subscribers s LEFT JOIN people.orbit_student_controls c ON c.phone=s.phone
          WHERE s.class_name=? AND s.status='waiting_for_class' ORDER BY s.phone""",(class_id,))]
        for r in rows:
            key=hashlib.sha256(json.dumps([r["phone"],class_id,r["joined_at"]]).encode()).hexdigest()
            previous=conn.execute("SELECT operation_id,status FROM orbit_class_ready_recipients WHERE enrollment_key=?",(key,)).fetchone()
            r["enrollment_key"]=key
            r["notification_status"]=previous["status"] if previous else "not_notified"
            r["eligible"]=bool(info["supported"] and r["activity_status"]=="allowed" and not r["signup"] and previous is None)
        safe_info={"id":info["id"],"name":info["name"],"supported":bool(info["supported"])}
        revision=hashlib.sha256(json.dumps([safe_info,rows],sort_keys=True,ensure_ascii=False).encode()).hexdigest()
        count=sum(r["eligible"] for r in rows)
        can_execute=bool(self.sender and info.get("template_verified") and info["supported"] and count)
        reason=None if can_execute else ("class_not_supported" if not info["supported"] else "no_eligible_students" if not count else "template_contract_unverified")
        return {"version":1,"class_id":class_id,"class_name":info["name"],"supported":info["supported"],
          "revision":revision,"eligible_count":count,"waiting_count":len(rows),"can_execute":can_execute,
          "disabled_reason":reason,"students":rows,"updated_at":int(time.time())}

    @contextmanager
    def connect(self, readonly=False):
        with self.store.connect(readonly) as c:
            uri=self.store.subscribers.resolve().as_uri()+("?mode=ro" if readonly else "?mode=rw")
            c.execute("ATTACH DATABASE ? AS people",(uri,))
            yield c

    def preview(self, class_id):
        with self.connect(True) as c:
            c.execute("BEGIN")
            return self._preview(c,class_id)

    def waiting(self):
        catalog=self.catalog()
        with self.connect(True) as c:
            c.execute("BEGIN")
            classes=[self._preview(c,item["id"]) for item in catalog]
        return {"version":1,"classes":classes,"updated_at":int(time.time()),
          "sending_enabled":bool(self.sender),
          "notice":"Notifications are invitations to opt in. Sending never subscribes a student or enables a scheduler."}

    def operation(self, identifier):
        try:
            if str(uuid.UUID(identifier))!=identifier: raise ValueError()
        except (ValueError,TypeError,AttributeError):raise Problem("invalid_request")
        with self.store.connect(True) as c:
            op=c.execute("SELECT * FROM orbit_class_ready_operations WHERE id=?",(identifier,)).fetchone()
            if op is None:raise Problem("operation_not_found",404)
            rows=c.execute("SELECT phone,status,error_code FROM orbit_class_ready_recipients WHERE operation_id=? ORDER BY phone",(identifier,)).fetchall()
        result=dict(op);result.pop("body_hash");result["request_id"]=result.pop("id")
        result.update(version=1,counts={s:sum(r["status"]==s for r in rows) for s in STATES},
                      recipients=[dict(r) for r in rows],total=len(rows))
        return result

    def submit(self, body):
        if not isinstance(body,dict) or set(body)!={"request_id","class_id","expected_revision","expected_eligible_count"}:raise Problem("invalid_request")
        identifier=body["request_id"];class_id=body["class_id"];revision=body["expected_revision"];count=body["expected_eligible_count"]
        try:
            if str(uuid.UUID(identifier))!=identifier:raise ValueError()
        except (ValueError,TypeError,AttributeError):raise Problem("invalid_request")
        if not isinstance(class_id,str) or len(class_id)>30 or not isinstance(revision,str) or not re.fullmatch("[a-f0-9]{64}",revision) or type(count) is not int or not 1<=count<=10000:raise Problem("invalid_request")
        digest=hashlib.sha256(json.dumps(body,sort_keys=True).encode()).hexdigest()
        replay=False
        with self.connect() as c:
            c.execute("BEGIN IMMEDIATE")
            existing=c.execute("SELECT body_hash FROM orbit_class_ready_operations WHERE id=?",(identifier,)).fetchone()
            if existing:
                if existing["body_hash"]!=digest:raise Problem("request_id_conflict",409)
                replay=True
            else:
                preview=self._preview(c,class_id)
                if not preview["supported"]:raise Problem("class_not_supported",409)
                if preview["revision"]!=revision or preview["eligible_count"]!=count:raise Problem("preview_changed",409)
                if not self.sender or not preview["can_execute"]:
                    c.execute("INSERT INTO orbit_class_ready_audit(request_id,class_id,action,created_at) VALUES(?,?,?,?)",
                              (identifier,class_id,"sending_disabled",int(time.time())))
                    c.commit()
                    raise Problem("sending_disabled",503)
                now=int(time.time())
                c.execute("INSERT INTO orbit_class_ready_operations VALUES(?,?,?,?,?,?,?)",(identifier,class_id,digest,revision,"reserved",now,now))
                c.executemany("INSERT INTO orbit_class_ready_recipients(operation_id,enrollment_key,phone,status) VALUES(?,?,?,'reserved')",
                              [(identifier,r["enrollment_key"],r["phone"]) for r in preview["students"] if r["eligible"]])
                c.execute("INSERT INTO orbit_class_ready_audit(request_id,class_id,action,created_at) VALUES(?,?,?,?)",(identifier,class_id,"reserved",now))
        if not replay:self.pool.submit(self.dispatch,identifier)
        return self.operation(identifier),200 if replay else 202

    def dispatch(self, identifier):
        # Never run on GET. Never retry. Pending reservations require manual review after a crash.
        with self.store.connect(True) as c:
            op=dict(c.execute("SELECT * FROM orbit_class_ready_operations WHERE id=?",(identifier,)).fetchone())
            rows=[dict(r) for r in c.execute("SELECT * FROM orbit_class_ready_recipients WHERE operation_id=?",(identifier,))]
        for row in rows:
            if row["status"]!="reserved":continue
            with self.connect() as c:
                c.execute("BEGIN IMMEDIATE")
                current=c.execute("SELECT status FROM orbit_class_ready_recipients WHERE operation_id=? AND phone=?",(identifier,row["phone"])).fetchone()
                if not current or current["status"]!="reserved":continue
                student=c.execute("""SELECT s.joined_at FROM people.subscribers s
                  LEFT JOIN people.orbit_student_controls r ON r.phone=s.phone
                  WHERE s.phone=? AND s.class_name=? AND s.status='waiting_for_class'
                  AND (r.activity_status IS NULL OR r.activity_status='allowed')
                  AND NOT EXISTS(SELECT 1 FROM people.signup_sessions p WHERE p.phone=s.phone)""",
                  (row["phone"],op["class_id"])).fetchone()
                key=hashlib.sha256(json.dumps([row["phone"],op["class_id"],student["joined_at"] if student else None]).encode()).hexdigest()
                info=next((v for v in self.catalog() if v["id"]==op["class_id"]),{})
                state,message,code="failed",None,"eligibility_changed"
                if student and key==row["enrollment_key"] and info.get("supported") and info.get("template_verified") and self.sender:
                    state,code="unknown",None
                    try:
                        result=self.sender(op["class_id"],row["phone"])
                        if result.get("status")=="accepted" and isinstance(result.get("message_id"),str) and result["message_id"]:
                            state,message="accepted",result["message_id"]
                        elif result.get("status")=="failed":state,code="failed","provider_rejected"
                    except Exception:code="outcome_unknown"
                c.execute("UPDATE orbit_class_ready_recipients SET status=?,message_id=?,error_code=? WHERE operation_id=? AND phone=?",
                          (state,message,code,identifier,row["phone"]))
        with self.store.connect() as c:
            c.execute("UPDATE orbit_class_ready_operations SET status='complete',updated_at=? WHERE id=?",(int(time.time()),identifier))
            c.execute("INSERT INTO orbit_class_ready_audit(request_id,class_id,action,created_at) VALUES(?,?,?,?)",(identifier,op["class_id"],"complete",int(time.time())))

def catalog_factory(subscribers, root):
    def catalog():
        c=sqlite3.connect(Path(subscribers).resolve().as_uri()+"?mode=ro",uri=True)
        try:classes={r[0] for r in c.execute("SELECT DISTINCT class_name FROM subscribers")}
        finally:c.close()
        known={}
        for directory in sorted(Path(root).glob("classera-*")):
            if not directory.is_dir():continue
            values=read_env(directory/".env");class_id=values.get("CLASSERA_CLASS")
            if not class_id:continue
            enabled=values.get("CLASSERA_ENABLED","1").lower() not in ("0","false","no")
            # Availability is configuration-based, never a scheduler activation action.
            provider=values.get("WHATSAPP_PROVIDER","meta")
            if provider=="kapso":
                shared=read_env(Path(root)/"shared/kapso.env")
                configured=bool(shared.get("KAPSO_API_KEY") and shared.get("KAPSO_PHONE_NUMBER_ID"))
            else:configured=bool(values.get("WHATSAPP_TOKEN") or values.get("WA_TOKEN"))
            known[class_id]={"id":class_id,"name":class_id,"supported":bool(enabled and configured),
                             "template_verified":False}
        return [known.get(k,{"id":k,"name":k,"supported":False,"template_verified":False}) for k in sorted(classes|set(known))]
    return catalog

def register(app,owner_token,store=None,catalog=None,sender=None):
    store=store or Store()
    catalog=catalog or catalog_factory(store.subscribers,"/home/local/classera")
    service=ClassReady(store,catalog,sender)
    # In production sender=None: no guessed template payload or provider call can occur.
    def authorized():
        supplied=request.headers.get("Authorization","")
        if not owner_token or not hmac.compare_digest(supplied.encode(),("Bearer "+owner_token).encode()):raise Problem("unauthorized",401)
        if request.headers.get("Origin") or request.headers.get("Sec-Fetch-Site")=="cross-site":raise Problem("owner_not_permitted",403)

    def endpoint(handler):
        def wrapped(**kwargs):
            try:
                authorized()
                if request.method=="POST" and (request.content_length is None or request.content_length>2048 or not request.is_json):raise Problem("invalid_request",422)
                result=handler(**kwargs)
                data,status=result if isinstance(result,tuple) else (result,200)
                response=jsonify(data);response.status_code=status
            except Problem as e:response=jsonify(version=1,error=e.code);response.status_code=e.status
            except (ValueError,TypeError):response=jsonify(version=1,error="invalid_request");response.status_code=422
            except (sqlite3.Error,OSError):response=jsonify(version=1,error="monitoring_unavailable");response.status_code=503
            response.headers["Cache-Control"]="no-store"
            return response
        return wrapped
    routes=[
      ("/api/classera/waiting-list","orbit_classera_waiting",["GET"],lambda:service.waiting()),
      ("/api/classera/class-ready/preview","orbit_classera_preview",["GET"],lambda:service.preview(request.args.get("class_id",""))),
      ("/api/classera/class-ready/operations","orbit_classera_submit",["POST"],lambda:service.submit(request.get_json(silent=True))),
      ("/api/classera/class-ready/operations/<identifier>","orbit_classera_operation",["GET"],lambda identifier:service.operation(identifier)),
      ("/api/classera/delivery-history","orbit_classera_history",["GET"],lambda:store.history(request.args)),
      ("/api/classera/daily-statistics","orbit_classera_statistics",["GET"],lambda:store.statistics(request.args))]
    for path,name,methods,handler in routes:app.add_url_rule(path,name,endpoint(handler),methods=methods)
    return service
