import json
import sqlite3
import tempfile
import unittest
from pathlib import Path
from flask import Flask
from classera_students import Directory, register
from classera_access import can_reply

class DirectoryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.path = Path(self.tmp.name) / "test.sqlite3"
        with sqlite3.connect(self.path) as c:
            c.executescript("CREATE TABLE subscribers(phone TEXT,name TEXT,class_name TEXT,ai_enabled INTEGER,status TEXT,joined_at TEXT,updated_at TEXT,PRIMARY KEY(phone,class_name)); CREATE TABLE signup_sessions(phone TEXT PRIMARY KEY,step TEXT,name TEXT,class_name TEXT,updated_at TEXT);")
        self.directory = Directory(self.path)
        with sqlite3.connect(self.path) as c:
            c.execute('CREATE TABLE orbit_student_controls(phone TEXT PRIMARY KEY,activity_status TEXT NOT NULL,updated_at TEXT NOT NULL)')
        self.app = Flask(__name__)
        register(self.app, "test-owner", self.directory)
        self.client = self.app.test_client()
        self.headers = {"Authorization": "Bearer test-owner"}
        self.phone = "201000000001"
        self.url = "/api/classera-students/" + self.phone
    def tearDown(self): self.tmp.cleanup()
    def test_other_class_edit_preserves_existing_opt_out_and_preferences(self):
        with self.directory.connect() as c:
            c.executemany("INSERT INTO subscribers VALUES(?,?,?,?,?,?,?)",[
                (self.phone,'Student','12F',0,'opted_out','old','before'),
                (self.phone,'Student','12E',0,'active','old','before')])
        current=self.directory.get(self.phone)
        rows=[{key:r[key] for key in ['class_name','name','ai_enabled','status']} for r in current['subscriptions']]
        next(r for r in rows if r['class_name']=='12E')['ai_enabled']=1
        updated=self.directory.save(self.phone,{'expected_revision':current['revision'],'subscriptions':rows})
        by_class={r['class_name']:r for r in updated['subscriptions']}
        self.assertEqual(by_class['12F']['status'],'opted_out')
        self.assertEqual(by_class['12F']['ai_enabled'],0)
        self.assertEqual(by_class['12F']['joined_at'],'old')
        self.assertEqual(by_class['12E']['ai_enabled'],1)

    def test_cannot_invent_opt_out_or_change_preserved_opt_out_ai(self):
        with self.directory.connect() as c:
            c.execute("INSERT INTO subscribers VALUES(?,?,?,?,?,?,?)",(self.phone,'Student','12F',0,'opted_out','old','before'))
        current=self.directory.get(self.phone)
        for rows in [[self.row('12F',ai=1,status='opted_out')],
                     [self.row('12F',ai=0,status='opted_out'),self.row('12E',ai=None,status='opted_out')]]:
            response=self.client.put(self.url,headers=self.headers,json={'expected_revision':current['revision'],'subscriptions':rows})
            self.assertEqual(response.status_code,422)
            self.assertEqual(self.directory.get(self.phone),current)
    def test_paused_and_opted_out_round_trip_every_ai_preference_without_reactivation(self):
        for status in ['paused','opted_out']:
            for preference in [None,0,1]:
                with self.directory.connect() as c:
                    c.execute('DELETE FROM subscribers WHERE phone=?',(self.phone,))
                    c.executemany('INSERT INTO subscribers VALUES(?,?,?,?,?,?,?)',[
                        (self.phone,'Student','12F',preference,status,'joined-original','before'),
                        (self.phone,'Student','12E',0,'active','joined-other','before')])
                current=self.directory.get(self.phone)
                rows=[{key:r[key] for key in ['class_name','name','ai_enabled','status']} for r in current['subscriptions']]
                for row in rows:
                    row['name']='Renamed'
                    if row['class_name']=='12E':row['ai_enabled']=1
                response=self.client.put(self.url,headers=self.headers,json={'expected_revision':current['revision'],'subscriptions':rows})
                self.assertEqual(response.status_code,200)
                saved={r['class_name']:r for r in response.get_json()['subscriptions']}
                self.assertEqual(saved['12F']['status'],status)
                self.assertEqual(saved['12F']['ai_enabled'],preference)
                self.assertEqual(saved['12F']['joined_at'],'joined-original')
                self.assertEqual(saved['12E']['ai_enabled'],1)
    def test_cannot_invent_paused_or_switch_between_preserved_states(self):
        with self.directory.connect() as c:
            c.execute('INSERT INTO subscribers VALUES(?,?,?,?,?,?,?)',(self.phone,'Student','12F',1,'paused','old','before'))
        current=self.directory.get(self.phone)
        for rows in [[self.row('12F',ai=0,status='paused')],
                     [self.row('12F',ai=1,status='opted_out')],
                     [self.row('12F',ai=1,status='paused'),self.row('12E',ai=1,status='paused')]]:
            response=self.client.put(self.url,headers=self.headers,json={'expected_revision':current['revision'],'subscriptions':rows})
            self.assertEqual(response.status_code,422)
            self.assertEqual(self.directory.get(self.phone),current)
    def test_class_resume_keeps_admin_suspension_and_excludes_report_recipient(self):
        with self.directory.connect() as c:
            c.execute('INSERT INTO subscribers VALUES(?,?,?,?,?,?,?)',(self.phone,'Student','12F',1,'paused','old','before'))
            c.execute('INSERT INTO orbit_student_controls VALUES(?,?,?)',(self.phone,'suspended','before'))
        current=self.directory.get(self.phone)
        response=self.client.put(self.url,headers=self.headers,json={
            'expected_revision':current['revision'],'subscriptions':[self.row('12F',ai=1,status='active')]})
        self.assertEqual(response.status_code,200)
        self.assertEqual(response.get_json()['activity_status'],'suspended')
        self.assertEqual(self.directory.recipients('classera-1'),[])
        self.assertFalse(can_reply(self.phone,path=self.path))
        with self.directory.connect() as c:
            self.assertEqual(c.execute('SELECT activity_status FROM orbit_student_controls WHERE phone=?',(self.phone,)).fetchone()[0],'suspended')
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
        self.assertEqual(self.put([]).status_code,403)
        self.assertEqual([r["class_name"] for r in self.directory.get(self.phone)["subscriptions"]],["12F","OLD"])
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

    def test_activity_enforces_recipients_and_remove_is_scoped(self):
        from classera_access import can_reply
        self.put([self.row(),self.row('12E')])
        for status in ('blocked','suspended','allowed'):
            current=self.directory.get(self.phone)
            response=self.client.put(self.url+'/activity',headers=self.headers,json={'expected_revision':current['revision'],'activity_status':status})
            self.assertEqual(response.status_code,200)
            self.assertEqual(can_reply(self.phone,self.path),status=='allowed')
            self.assertEqual(can_reply('+'+self.phone,self.path),status=='allowed')
            self.assertEqual(self.directory.recipients('classera-1'),[self.phone] if status=='allowed' else [])
        before=self.directory.get(self.phone)
        self.assertEqual(self.client.delete(self.url,headers=self.headers,json={'expected_revision':'0'*64}).status_code,403)
        self.assertEqual(self.client.delete(self.url,headers=self.headers,json={'expected_revision':before['revision']}).status_code,403)
        self.assertEqual(self.directory.get(self.phone)['subscriptions'],before['subscriptions'])
        self.assertTrue(can_reply(self.phone,self.path))

    def test_reply_gate_fails_closed(self):
        from classera_access import can_reply
        self.assertFalse(can_reply(self.phone,Path(self.tmp.name)/'missing.db'))
        self.assertFalse(can_reply('not-a-number',self.path))

if __name__ == "__main__": unittest.main()

