"""Additive Classera monitoring. No provider credentials or network transport."""
from contextlib import contextmanager
import contextvars
import hashlib
import json
import re
import sqlite3
import time
import uuid
from datetime import date, datetime, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

DB = Path("/home/local/classera/shared/delivery_state.db")
SUBSCRIBERS = Path("/home/local/classera/shared/subscribers.sqlite3")
CAIRO = ZoneInfo("Africa/Cairo")
STATES = ("reserved", "accepted", "sent", "delivered", "read", "failed", "unknown")
_CONTEXT = contextvars.ContextVar("orbit_report_context", default=None)

def timestamp(value):
    try:
        if isinstance(value, (int, float)) or str(value).isdigit(): return int(value)
        parsed=datetime.fromisoformat(str(value).replace("Z","+00:00"))
        if parsed.tzinfo is None:parsed=parsed.replace(tzinfo=timezone.utc)
        return int(parsed.timestamp())
    except (ValueError, TypeError, OverflowError): return None

def report_date(report, historical=False):
    match = re.search(r"(?:^|\D)(\d{1,2})[_-](\d{1,2})[_-](\d{4}|\d{2})(?:\D|$)", report)
    if match:
        d, m, y = map(int, match.groups())
        try: return date(2000 + y if y < 100 else y, m, d).isoformat()
        except ValueError: return None
    if not historical:
        match = re.search(r"(?:^|\D)(\d{1,2})[_-](\d{1,2})(?:\D|$)", report)
        if match:
            try: return date(datetime.now(CAIRO).year, int(match[2]), int(match[1])).isoformat()
            except ValueError: pass
    return None

def klass(identifier, report=""):
    value = {"classera-1": "12F", "classera-2": "12E", "classera-3": "12D"}.get(identifier)
    if value: return value
    match = re.match(r"^(\d{1,2}[A-Z])(?:\W|$)", report.upper())
    return match[1] if match else (identifier or "unknown")

class Store:
    def __init__(self, path=DB, subscribers=SUBSCRIBERS):
        self.path, self.subscribers = Path(path), Path(subscribers)

    @contextmanager
    def connect(self, readonly=False):
        conn = sqlite3.connect(self.path.resolve().as_uri() + ("?mode=ro" if readonly else "?mode=rw"), uri=True, timeout=5)
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA busy_timeout=5000")
        try:
            yield conn
            conn.commit()
        except Exception:
            conn.rollback();raise
        finally:conn.close()

    def migrate(self):
        # Explicit startup migration only. GET endpoints never migrate or send.
        with self.connect() as c:
            c.executescript("""
            CREATE TABLE IF NOT EXISTS orbit_report_runs(
              id TEXT PRIMARY KEY,report TEXT NOT NULL,class_id TEXT NOT NULL,report_date TEXT,created_at INTEGER NOT NULL,expected_known INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS orbit_report_skips(run_id TEXT NOT NULL,phone TEXT NOT NULL,PRIMARY KEY(run_id,phone));
            CREATE TABLE IF NOT EXISTS orbit_report_targets(
              report TEXT NOT NULL,class_id TEXT NOT NULL,report_date TEXT NOT NULL,phone TEXT NOT NULL,
              PRIMARY KEY(report,class_id,report_date,phone));
            CREATE TABLE IF NOT EXISTS orbit_delivery_attempts(
              id TEXT PRIMARY KEY,legacy_key TEXT UNIQUE,run_id TEXT,report TEXT NOT NULL,
              report_date TEXT,class_id TEXT NOT NULL,phone TEXT NOT NULL,template TEXT,
              message_id TEXT UNIQUE,status TEXT NOT NULL,created_at INTEGER,updated_at INTEGER NOT NULL,
              historical INTEGER NOT NULL DEFAULT 0);
            CREATE INDEX IF NOT EXISTS orbit_attempts_date ON orbit_delivery_attempts(report_date,class_id);
            CREATE TABLE IF NOT EXISTS orbit_delivery_events(
              id TEXT PRIMARY KEY,message_id TEXT NOT NULL,status TEXT NOT NULL,event_at INTEGER NOT NULL,received_at INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS orbit_class_ready_operations(
              id TEXT PRIMARY KEY,class_id TEXT NOT NULL,body_hash TEXT NOT NULL,revision TEXT NOT NULL,
              status TEXT NOT NULL,created_at INTEGER NOT NULL,updated_at INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS orbit_class_ready_recipients(
              operation_id TEXT NOT NULL,enrollment_key TEXT NOT NULL UNIQUE,phone TEXT NOT NULL,
              status TEXT NOT NULL,message_id TEXT UNIQUE,error_code TEXT,
              PRIMARY KEY(operation_id,phone));
            CREATE TABLE IF NOT EXISTS orbit_class_ready_audit(
              id INTEGER PRIMARY KEY,request_id TEXT,class_id TEXT,action TEXT NOT NULL,created_at INTEGER NOT NULL);
            """)
            # Preserve originals. Imported rows are last-known snapshots, not invented events.
            if c.execute("SELECT 1 FROM sqlite_master WHERE name='deliveries'").fetchone():
                for row in c.execute("SELECT * FROM deliveries").fetchall():
                    state = "reserved" if row["status"] == "sending" else row["status"]
                    if state not in STATES: state = "unknown"
                    message = row["message_id"]
                    # A forced attempt already observed by the new hook must not be duplicated.
                    if message and c.execute("SELECT 1 FROM orbit_delivery_attempts WHERE message_id=?", (message,)).fetchone(): continue
                    c.execute("""INSERT OR IGNORE INTO orbit_delivery_attempts
                      (id,legacy_key,report,report_date,class_id,phone,template,message_id,status,created_at,updated_at,historical)
                      VALUES(?,?,?,?,?,?,NULL,?,?,NULL,?,1)""",
                      ("legacy:"+row["delivery_key"], row["delivery_key"], row["report"], report_date(row["report"], True),
                       klass(row["classera_id"],row["report"]),row["recipient"],message,state,timestamp(row["updated_at"]) or 0))

    def names(self):
        c = sqlite3.connect(self.subscribers.resolve().as_uri()+"?mode=ro", uri=True, timeout=5)
        try: return {(r[0],r[1]):r[2] for r in c.execute("SELECT phone,class_name,name FROM subscribers")}
        finally: c.close()

    def begin(self, report, class_id, phones, forced=False):
        run = str(uuid.uuid4()); now = int(time.time()); day = report_date(report)
        with self.connect() as c:
            c.execute("INSERT INTO orbit_report_runs VALUES(?,?,?,?,?,?)",(run,report,class_id,day,now,not forced))
            c.executemany("INSERT OR IGNORE INTO orbit_report_targets VALUES(?,?,?,?)",
                          [(report,class_id,day or '',p) for p in set(phones)] if not forced else [])
        return run

    def attempt(self, run, phone, template):
        with self.connect() as c:
            row = c.execute("SELECT * FROM orbit_report_runs WHERE id=?", (run,)).fetchone()
            if not row: return None
            identifier = str(uuid.uuid4()); now = int(time.time())
            c.execute("""INSERT INTO orbit_delivery_attempts
              (id,run_id,report,report_date,class_id,phone,template,status,created_at,updated_at)
              VALUES(?,?,?,?,?,?,?,'reserved',?,?)""",
              (identifier,run,row["report"],row["report_date"],row["class_id"],phone,template,now,now))
            return identifier

    def result(self, identifier, status, message_id=None):
        if status not in STATES: status = "unknown"
        with self.connect() as c:
            c.execute("UPDATE orbit_delivery_attempts SET status=?,message_id=?,updated_at=? WHERE id=?",
                      (status,message_id,int(time.time()),identifier))
            if message_id:
                events = c.execute("SELECT * FROM orbit_delivery_events WHERE message_id=? ORDER BY event_at,received_at", (message_id,)).fetchall()
                for e in events: self._apply(c,message_id,e["status"],e["event_at"])

    @staticmethod
    def _apply(c, message_id, status, when):
        # Preserve confirmed later stages when provider events arrive out of order.
        levels={"reserved":0,"unknown":0,"accepted":1,"sent":2,"delivered":3,"read":4,"failed":2}
        for table in ["orbit_delivery_attempts","orbit_class_ready_recipients"]:
            row = c.execute("SELECT status FROM "+table+" WHERE message_id=?", (message_id,)).fetchone()
            if not row: continue
            if levels[status] < levels.get(row["status"],0): continue
            if row["status"] in ("delivered","read") and status=="failed": continue
            if row["status"]=="failed" and status in ("reserved","unknown","accepted","sent"): continue
            if table=="orbit_delivery_attempts":
                c.execute("UPDATE "+table+" SET status=?,updated_at=MAX(updated_at,?) WHERE message_id=?", (status,when,message_id))
            else: c.execute("UPDATE "+table+" SET status=? WHERE message_id=?", (status,message_id))

    def event(self, message_id, status, event_at=None):
        if not message_id or status not in ("sent","delivered","read","failed"): return
        now = int(time.time()); when = timestamp(event_at) or now
        key = hashlib.sha256(json.dumps([message_id,status,when]).encode()).hexdigest()
        with self.connect() as c:
            c.execute("INSERT OR IGNORE INTO orbit_delivery_events VALUES(?,?,?,?,?)",(key,message_id,status,when,now))
            self._apply(c,message_id,status,when)

    def history(self, query):
        clauses=[];args=[]
        for key,column in [("class_id","class_id"),("report","report"),("template","template"),("status","status"),("phone","phone"),("record_id","id")]:
            if query.get(key):
                if len(query[key])>300:raise ValueError("invalid_filter")
                if key=="status" and query[key] not in STATES:raise ValueError("invalid_status")
                clauses.append("a."+column+"=?");args.append(query[key])
        for key,operator in [("from",">="),("to","<=")]:
            if query.get(key):date.fromisoformat(query[key]);clauses.append("a.report_date"+operator+"?");args.append(query[key])
        limit=min(max(int(query.get("limit",30)),1),100);offset=max(int(query.get("offset",0)),0)
        sort={"date":"COALESCE(a.report_date,'')","updated":"a.updated_at","class":"a.class_id"}.get(query.get("sort","updated"))
        if sort is None:raise ValueError("invalid_sort")
        direction={"asc":"ASC","desc":"DESC"}.get(query.get("direction","desc"))
        if not direction:raise ValueError("invalid_direction")
        search=query.get("search","").strip()
        if len(search)>150:raise ValueError("invalid_search")
        if search:
            clauses.append("(a.phone LIKE ? ESCAPE '\\' OR s.name LIKE ? ESCAPE '\\' OR a.report LIKE ? ESCAPE '\\' OR a.message_id LIKE ? ESCAPE '\\')")
            literal="%"+search.replace("\\","\\\\").replace("%","\\%").replace("_","\\_")+"%"
            args.extend([literal]*4)
        where=" WHERE "+" AND ".join(clauses) if clauses else ""
        source=" FROM orbit_delivery_attempts a LEFT JOIN people.subscribers s ON s.phone=a.phone AND s.class_name=a.class_id"
        with self.connect(True) as conn:
            conn.execute("ATTACH DATABASE ? AS people",(self.subscribers.resolve().as_uri()+"?mode=ro",))
            conn.execute("BEGIN")
            total=conn.execute("SELECT COUNT(*)"+source+where,args).fetchone()[0]
            rows=[dict(r) for r in conn.execute("SELECT a.*,s.name AS student"+source+where+" ORDER BY "+sort+" "+direction+",a.id LIMIT ? OFFSET ?",args+[limit,offset])]
        for r in rows:r["historical"]=bool(r["historical"])
        return {"version":1,"records":rows,"total":total,"offset":offset,
                "next_offset":offset+limit if offset+limit<total else None,"updated_at":int(time.time()),
                "limitations":["Imported legacy rows lack template names, original attempt times and expected-recipient snapshots. Subscriber names reflect current profiles."]}

    def statistics(self, query):
        end=date.fromisoformat(query.get("to") or datetime.now(CAIRO).date().isoformat())
        start=date.fromisoformat(query.get("from") or end.isoformat())
        if start>end or (end-start).days>366:raise ValueError("invalid_range")
        with self.connect(True) as c:
            attempts=[dict(r) for r in c.execute("SELECT * FROM orbit_delivery_attempts")]
            targets=[dict(r) for r in c.execute("SELECT * FROM orbit_report_targets")]
            runs=[dict(r) for r in c.execute("SELECT * FROM orbit_report_runs")]
            skips=[dict(r) for r in c.execute("SELECT s.phone,r.report,r.class_id,r.report_date FROM orbit_report_skips s JOIN orbit_report_runs r ON s.run_id=r.id")]
        selected=query.get("class_id")
        valid=lambda r:r["report_date"] and start.isoformat()<=r["report_date"]<=end.isoformat() and (not selected or r["class_id"]==selected)
        a=[r for r in attempts if valid(r)];t=[r for r in targets if valid(r)];r=[v for v in runs if valid(v)]
        groups=sorted({(v["report_date"],v["class_id"],v["report"]) for v in a+t+r})
        reports=[]
        for day,cl,report in groups:
            aa=[v for v in a if (v["report_date"],v["class_id"],v["report"])==(day,cl,report)]
            tt=[v for v in t if (v["report_date"],v["class_id"],v["report"])==(day,cl,report)]
            known=any(v["expected_known"] and (v["report_date"],v["class_id"],v["report"])==(day,cl,report) for v in r) and not any(v["historical"] for v in aa)
            counts={s:sum(v["status"]==s for v in aa) for s in STATES}
            expected={v["phone"] for v in tt}
            delivered={v["phone"] for v in aa if v["status"] in ("delivered","read")}
            attempted={v["phone"] for v in aa}
            expected_count=len(expected) if known else None
            skipped={v["phone"] for v in skips if (v["report_date"],v["class_id"],v["report"])==(day,cl,report)}-attempted
            reports.append({"id":hashlib.sha256(json.dumps([day,cl,report]).encode()).hexdigest(),
              "date":day,"class_id":cl,"report":report,"counts":counts,"attempts":len(aa),
              "expected":expected_count,"delivered_targets":len(delivered & expected) if known else None,
              "not_attempted":len(expected-attempted-skipped) if known else None,
              "skipped":len(expected & skipped) if known else None,
              "delivery_rate":round(100*len(delivered & expected)/len(expected),2) if known and expected else None})
        templates=[]
        for name in sorted({v["template"] for v in a if v["template"]}):
            rows=[v for v in a if v["template"]==name]
            templates.append({"id":name,"template":name,"attempts":len(rows),
                              "counts":{state:sum(v["status"]==state for v in rows) for state in STATES}})
        missing=[v for v in a if not v["template"]]
        if missing:
            templates.append({"id":"__not_recorded__","template":None,"attempts":len(missing),
                              "counts":{state:sum(v["status"]==state for v in missing) for state in STATES}})
        counts={s:sum(v["counts"][s] for v in reports) for s in STATES}
        complete=bool(reports) and all(v["expected"] is not None for v in reports)
        denominator=sum(v["expected"] for v in reports) if complete else None
        numerator=sum(v["delivered_targets"] for v in reports) if complete else None
        return {"version":1,"from":start.isoformat(),"to":end.isoformat(),"updated_at":int(time.time()),
          "reports":reports,"templates":templates,"counts":counts,"attempts":sum(v["attempts"] for v in reports),
          "expected":denominator,"delivered_targets":numerator,
          "not_attempted":sum(v["not_attempted"] for v in reports) if complete else None,
          "skipped":sum(v["skipped"] for v in reports) if complete else None,"delivery_rate":round(100*numerator/denominator,2) if denominator else None,
          "unknown_date_records":sum(v["report_date"] is None for v in attempts),
          "limitations":["Expected recipients are captured when a report enters the sender. Earlier missed schedules cannot be reconstructed.",
            "Legacy rows are last-known snapshots; overwritten earlier attempts and missing webhook events cannot be recovered.",
            "Status categories count each message/attempt once. Delivery rate uses unique delivered/read recipient-report targets.",
            "Skipped and not-attempted are separate only for newly observed complete reports; historical values remain unavailable."]}

def begin_report(report, class_id, phones, forced=False):
    try:
        store=Store();run=store.begin(report,class_id,phones,forced);_CONTEXT.set(run)
    except (sqlite3.Error,OSError,ValueError):_CONTEXT.set(None)

def before_send(phone, template):
    try:
        run=_CONTEXT.get()
        return Store().attempt(run,phone,template) if run else None
    except (sqlite3.Error,OSError,ValueError):return None

def after_send(identifier, response=None):
    if not identifier:return
    state="unknown";message=None
    if response is not None:
        try:
            body=response.json();messages=body.get("messages",[]) if isinstance(body,dict) else []
            if response.ok and messages and isinstance(messages[0].get("id"),str):
                state="accepted";message=messages[0]["id"]
            elif 400<=response.status_code<500:state="failed"
        except (ValueError,TypeError,AttributeError,IndexError):pass
    try:Store().result(identifier,state,message)
    except (sqlite3.Error,OSError,ValueError):pass

def observe_status(message_id,status,event_at=None):
    try:Store().event(message_id,status,event_at)
    except (sqlite3.Error,OSError,ValueError):pass

def record_skip(phone):
    try:
        run=_CONTEXT.get()
        if run:
            with Store().connect() as c:c.execute("INSERT OR IGNORE INTO orbit_report_skips VALUES(?,?)",(run,phone))
    except (sqlite3.Error,OSError,ValueError):pass
