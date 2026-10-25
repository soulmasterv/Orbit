import json
import sqlite3
import tempfile
import unittest
from pathlib import Path
from flask import Flask
from classera_students import Directory, register

class DirectoryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.path = Path(self.tmp.name) / "test.sqlite3"
        with sqlite3.connect(self.path) as c:
            c.executescript("CREATE TABLE subscribers(phone TEXT,name TEXT,class_name TEXT,ai_enabled INTEGER,status TEXT,joined_at TEXT,updated_at TEXT,PRIMARY KEY(phone,class_name)); CREATE TABLE signup_sessions(phone TEXT PRIMARY KEY,step TEXT,name TEXT,class_name TEXT,updated_at TEXT);")
        self.directory = Directory(self.path)
        self.app = Flask(__name__)
        register(self.app, "test-owner", self.directory)
        self.client = self.app.test_client()
        self.headers = {"Authorization": "Bearer test-owner"}
        self.phone = "201000000001"
        self.url = "/api/classera-students/" + self.phone
    def tearDown(self): self.tmp.cleanup()
    def row(self, klass="12F", ai=1, status="active"):
        return dict(class_name=klass, name="Test Student", ai_enabled=ai, status=status)
    def put(self, rows, revision=None):
        revision = revision or self.directory.get(self.phone)["revision"]
        return self.client.put(self.url, headers=self.headers, json=dict(expected_revision=revision, subscriptions=rows))
    def test_auth_no_store_and_origin(self):
        self.assertEqual(self.client.get(self.url).status_code, 401)
        self.assertEqual(self.client.get(self.url, headers={"X-API-Key":"test-owner"}).status_code,401)
        self.assertEqual(self.client.put(self.url,json={},headers={**self.headers,"Origin":"https://evil.example"}).status_code,403)
        self.assertEqual(self.client.get(self.url,headers=self.headers).headers["Cache-Control"],"no-store")
    def test_two_classes_shared_reads_and_ai_null(self):
        r = self.put([self.row(),self.row("12E",None,"waiting_for_class")])
        self.assertEqual(r.status_code,200)
        self.assertEqual(len(r.json["subscriptions"]),2)
        self.assertEqual(self.directory.recipients("classera-1"),[self.phone])
        self.assertEqual(self.directory.recipients("classera-2"),[])
        self.assertEqual(len(self.client.get("/api/classera-students",headers=self.headers).json["students"]),1)
        with sqlite3.connect(self.path) as c:
            c.execute("UPDATE subscribers SET name='WhatsApp update' WHERE phone=? AND class_name='12F'",(self.phone,))
        self.assertEqual(self.directory.get(self.phone)["subscriptions"][1]["name"],"WhatsApp update")
    def test_stale_write_rollback_preserve_joined_unknown_and_other_phone(self):
        self.put([self.row()])
        before = self.directory.get(self.phone)
        with sqlite3.connect(self.path) as c:
            c.execute("INSERT INTO subscribers VALUES(?,?,?,?,?,?,?)",(self.phone,"Legacy","OLD",None,"active","old","old"))
            c.execute("INSERT INTO subscribers VALUES(?,?,?,?,?,?,?)",("201000000002","Other","12E",0,"active","old","old"))
        self.assertEqual(self.put([],before["revision"]).status_code,409)
        current = self.directory.get(self.phone)
        joined = current["subscriptions"][0]["joined_at"]
        self.assertEqual(self.put([self.row(ai=0)]).status_code,200)
        self.assertEqual(self.directory.get(self.phone)["subscriptions"][0]["joined_at"],joined)
        self.assertEqual(self.put([]).status_code,200)
        self.assertEqual([r["class_name"] for r in self.directory.get(self.phone)["subscriptions"]],["OLD"])
        self.assertEqual(len(self.directory.get("201000000002")["subscriptions"]),1)
    def test_signup_session_preserved_and_conflicts(self):
        with sqlite3.connect(self.path) as c:
            c.execute("INSERT INTO signup_sessions VALUES(?,?,?,?,?)",(self.phone,"ai","Pending","12E","now"))
        self.assertEqual(self.put([self.row()]).status_code,409)
        self.assertEqual(self.directory.get(self.phone)["signup_session"]["step"],"ai")
    def test_validation_atomic_no_new_database(self):
        for rows in [[self.row(),self.row()], [self.row("12X")], [self.row(ai=True)], [self.row(ai=1,status="waiting_for_class")], [{**self.row(),"name":""}]]:
            self.assertEqual(self.put(rows).status_code,422)
        self.assertEqual(self.directory.get(self.phone)["subscriptions"],[])
        self.assertEqual(self.client.get("/api/classera-students/not-a-phone",headers=self.headers).status_code,422)
        missing=Path(self.tmp.name)/"missing.sqlite3"
        with self.assertRaises(sqlite3.Error): Directory(missing).listing()
        self.assertFalse(missing.exists())

if __name__ == "__main__": unittest.main()
