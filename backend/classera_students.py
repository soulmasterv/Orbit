"""Owner-only Classera directory; never calls messaging/provider code."""
import hashlib
import hmac
import json
import re
import sqlite3
from contextlib import contextmanager
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo
from flask import jsonify, request

CLASSES = {"classera-1": "12F", "classera-2": "12E"}
DB = "/home/local/classera/shared/subscribers.sqlite3"

class Invalid(Exception): pass
class Conflict(Exception): pass

def phone_value(value):
    if not isinstance(value, str) or not re.fullmatch(r"[1-9][0-9]{7,14}", value):
        raise Invalid()
    return value

class Directory:
    def __init__(self, path=DB): self.path = Path(path)

    @contextmanager
    def connect(self):
        # mode=rw: a missing database must never create a second empty database.
        conn = sqlite3.connect(self.path.resolve().as_uri() + "?mode=rw", uri=True, timeout=5)
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA busy_timeout=5000")
        try:
            with conn: yield conn
        finally: conn.close()

    def record(self, conn, phone):
        rows = [dict(r) for r in conn.execute(
            "SELECT phone,name,class_name,ai_enabled,status,joined_at,updated_at FROM subscribers WHERE phone=? ORDER BY class_name", (phone,))]
        session = conn.execute("SELECT phone,step,name,class_name,updated_at FROM signup_sessions WHERE phone=?", (phone,)).fetchone()
        session = dict(session) if session else None
        raw = json.dumps([phone, rows, session], ensure_ascii=False, sort_keys=True, separators=(",", ":"))
        return {"phone": phone, "subscriptions": rows, "signup_session": session,
                "revision": hashlib.sha256(raw.encode()).hexdigest()}

    def get(self, phone):
        phone_value(phone)
        with self.connect() as conn:
            conn.execute("BEGIN")
            return self.record(conn, phone)

    def listing(self):
        with self.connect() as conn:
            conn.execute("BEGIN")
            phones = conn.execute("SELECT phone FROM (SELECT phone,updated_at FROM subscribers UNION ALL SELECT phone,updated_at FROM signup_sessions) GROUP BY phone ORDER BY MAX(updated_at) DESC,phone").fetchall()
            return {"version": 1, "students": [self.record(conn, r["phone"]) for r in phones],
                    "classes": [{"id": k, "class_name": v} for k,v in CLASSES.items()]}

    def save(self, phone, data):
        phone_value(phone)
        if not isinstance(data, dict) or set(data) != {"expected_revision", "subscriptions"}: raise Invalid()
        revision, rows = data["expected_revision"], data["subscriptions"]
        if not isinstance(revision, str) or not re.fullmatch(r"[a-f0-9]{64}", revision): raise Invalid()
        if not isinstance(rows, list) or len(rows) > 2: raise Invalid()
        seen = set()
        for row in rows:
            if not isinstance(row, dict) or set(row) != {"class_name", "name", "ai_enabled", "status"}: raise Invalid()
            klass, name, ai, status = (row[k] for k in ("class_name", "name", "ai_enabled", "status"))
            if klass not in CLASSES.values() or klass in seen: raise Invalid()
            if not isinstance(name, str) or not name.strip() or len(name) > 120 or any(ord(c) < 32 for c in name): raise Invalid()
            if ai is not None and (type(ai) is not int or ai not in (0,1)): raise Invalid()
            if status not in ("active", "waiting_for_class"): raise Invalid()
            if status == "waiting_for_class" and ai is not None: raise Invalid()
            seen.add(klass)
        with self.connect() as conn:
            conn.execute("BEGIN IMMEDIATE")
            current = self.record(conn, phone)
            if not hmac.compare_digest(current["revision"], revision): raise Conflict()
            # Do not overwrite a live WhatsApp onboarding conversation.
            if current["signup_session"] is not None: raise Conflict()
            ts = datetime.now(ZoneInfo("Africa/Cairo")).isoformat()
            for klass in CLASSES.values():
                if klass not in seen:
                    conn.execute("DELETE FROM subscribers WHERE phone=? AND class_name=?", (phone, klass))
            for row in rows:
                conn.execute("""INSERT INTO subscribers(phone,name,class_name,ai_enabled,status,joined_at,updated_at)
                    VALUES(?,?,?,?,?,?,?) ON CONFLICT(phone,class_name) DO UPDATE SET
                    name=excluded.name,ai_enabled=excluded.ai_enabled,status=excluded.status,updated_at=excluded.updated_at""",
                    (phone,row["name"].strip(),row["class_name"],row["ai_enabled"],row["status"],ts,ts))
            # Unknown/legacy classes and joined_at on existing rows remain intact.
            return self.record(conn, phone)

    def recipients(self, identifier):
        klass = CLASSES.get(identifier)
        if klass is None: raise Invalid()
        with self.connect() as conn:
            return [r[0] for r in conn.execute("SELECT phone FROM subscribers WHERE status='active' AND UPPER(class_name)=? ORDER BY joined_at,phone", (klass,))]

def register(app, owner_token, directory=None):
    directory = directory or Directory()

    def handle(phone=None):
        # Same owner credential as Orbit, supplied at runtime from Keychain.
        supplied = request.headers.get("Authorization", "")
        if not owner_token or not hmac.compare_digest(supplied.encode(), ("Bearer " + owner_token).encode()):
            return jsonify(error="unauthorized"), 401
        if request.headers.get("Origin") or request.headers.get("Sec-Fetch-Site") == "cross-site":
            return jsonify(error="owner_not_permitted"), 403
        try:
            if request.method == "PUT":
                if request.content_length is None or request.content_length > 8192 or not request.is_json:
                    return jsonify(error="invalid_request"), 422
                result = directory.save(phone, request.get_json(silent=True))
            else: result = directory.get(phone) if phone else directory.listing()
            return jsonify(result), 200
        except Invalid: return jsonify(error="invalid_input"), 422
        except Conflict: return jsonify(error="review_latest_or_finish_signup"), 409
        except (sqlite3.Error, OSError): return jsonify(error="directory_unavailable"), 503

    app.add_url_rule("/api/classera-students", "classera_student_list", handle, methods=["GET"])
    app.add_url_rule("/api/classera-students/<phone>", "classera_student_detail", handle, methods=["GET", "PUT"])

    @app.after_request
    def private_directory(response):
        if request.path.startswith("/api/classera-students"):
            response.headers["Cache-Control"] = "no-store"
        return response
