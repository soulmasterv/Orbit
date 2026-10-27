import json
import sqlite3
import tempfile
import time
import unittest
import uuid
from concurrent.futures import ThreadPoolExecutor
from unittest.mock import patch
from pathlib import Path
from flask import Flask
from orbit_classera_monitor import Store, report_date
from classera_monitoring_api import register, ClassReady, Problem

class ClasseraMonitoringTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();root=Path(self.temp.name)
        self.db=root/"delivery.db";self.people=root/"people.db"
        with sqlite3.connect(self.db) as c:
            c.execute("CREATE TABLE deliveries(delivery_key TEXT PRIMARY KEY,report TEXT,recipient TEXT,status TEXT,message_id TEXT,updated_at TEXT,classera_id TEXT)")
        with sqlite3.connect(self.people) as c:
            c.executescript("""
              CREATE TABLE subscribers(phone TEXT,name TEXT,class_name TEXT,ai_enabled INTEGER,status TEXT,joined_at TEXT,updated_at TEXT,PRIMARY KEY(phone,class_name));
              CREATE TABLE signup_sessions(phone TEXT PRIMARY KEY,step TEXT,name TEXT,class_name TEXT,updated_at TEXT);
              CREATE TABLE orbit_student_controls(phone TEXT PRIMARY KEY,activity_status TEXT,updated_at TEXT);
            """)
            c.executemany("INSERT INTO subscribers VALUES (?,?,?,NULL,'waiting_for_class','2026-10-01T10:00:00+03:00','2026-10-01')",
              [("201000000001","One","12F"),("201000000002","Two","12F"),("201000000003","Three","12D")])
        self.store=Store(self.db,self.people);self.store.migrate()
        self.verified=False;self.calls=[]
        self.catalog=lambda:[{"id":"12F","name":"12F","supported":True,"template_verified":self.verified},
                             {"id":"12D","name":"12D","supported":False,"template_verified":False}]
        self.app=Flask(__name__);self.app.testing=True
        self.service=register(self.app,"owner-placeholder",self.store,self.catalog)
        self.client=self.app.test_client();self.auth={"Authorization":"Bearer owner-placeholder"}
        self.pools=[]

    def tearDown(self):
        for pool in self.pools:pool.shutdown(wait=True)
        self.temp.cleanup()

    def post_body(self,preview):
        return {"request_id":str(uuid.uuid4()),"class_id":preview["class_id"],
                "expected_revision":preview["revision"],"expected_eligible_count":preview["eligible_count"]}

    def verified_service(self, sender=None):
        self.verified=True
        def fake(klass,phone):
            self.calls.append((klass,phone))
            return {"status":"accepted","message_id":"mock-"+phone}
        service=ClassReady(self.store,self.catalog,sender or fake)
        self.pools.append(service.pool)
        return service

    def test_authentication_no_origin_no_api_key_and_no_store(self):
        for path in ["/api/classera/waiting-list","/api/classera/delivery-history","/api/classera/daily-statistics?from=2026-10-01&to=2026-10-31"]:
            self.assertEqual(self.client.get(path).status_code,401)
            self.assertEqual(self.client.get(path,headers={"X-API-Key":"owner-placeholder"}).status_code,401)
            response=self.client.get(path,headers=self.auth)
            self.assertEqual(response.status_code,200)
            self.assertEqual(response.headers["Cache-Control"],"no-store")
            self.assertEqual(self.client.get(path,headers={**self.auth,"Origin":"https://example.invalid"}).status_code,403)

    def test_preview_readonly_and_execution_disabled_without_reservation(self):
        before=sqlite3.connect(self.people).execute("SELECT * FROM subscribers ORDER BY phone").fetchall()
        response=self.client.get("/api/classera/class-ready/preview?class_id=12F",headers=self.auth)
        p=response.get_json();self.assertEqual(p["eligible_count"],2);self.assertFalse(p["can_execute"])
        r=self.client.post("/api/classera/class-ready/operations",json=self.post_body(p),headers=self.auth)
        self.assertEqual(r.status_code,503);self.assertEqual(r.get_json()["error"],"sending_disabled")
        with self.store.connect(True) as c:
            self.assertEqual(c.execute("SELECT COUNT(*) FROM orbit_class_ready_recipients").fetchone()[0],0)
            self.assertEqual(c.execute("SELECT COUNT(*) FROM orbit_class_ready_audit").fetchone()[0],1)
        self.assertEqual(sqlite3.connect(self.people).execute("SELECT * FROM subscribers ORDER BY phone").fetchall(),before)
        self.assertEqual(self.calls,[])

    def test_preview_excludes_restricted_signup_and_not_supported(self):
        with sqlite3.connect(self.people) as c:
            c.execute("INSERT INTO orbit_student_controls VALUES ('201000000001','suspended','now')")
            c.execute("INSERT INTO signup_sessions VALUES ('201000000002','class',NULL,NULL,'now')")
        p=self.service.preview("12F");self.assertEqual(p["eligible_count"],0)
        self.assertFalse(self.service.preview("12D")["supported"])
        self.assertFalse(self.service.preview("12D")["students"][0]["eligible"])
        with self.assertRaises(Problem):self.service.preview("not-real")

    def test_stale_revision_count_uuid_and_input_fail_without_send(self):
        p=self.service.preview("12F")
        body=self.post_body(p);body["expected_eligible_count"]=1
        self.assertEqual(self.client.post("/api/classera/class-ready/operations",json=body,headers=self.auth).status_code,409)
        for mutation in [{"expected_eligible_count":True},{"expected_revision":"bad"},{"request_id":"bad"},{"extra":True}]:
            b={**self.post_body(p),**mutation}
            self.assertEqual(self.client.post("/api/classera/class-ready/operations",json=b,headers=self.auth).status_code,422)
        with self.store.connect(True) as c:self.assertEqual(c.execute("SELECT COUNT(*) FROM orbit_class_ready_operations").fetchone()[0],0)

    def test_atomic_reservation_idempotency_and_no_automatic_activation(self):
        service=self.verified_service();preview=service.preview("12F");body=self.post_body(preview)
        result,status=service.submit(body);self.assertEqual(status,202)
        service.pool.shutdown(wait=True)
        result,status=service.submit(body);self.assertEqual(status,200)
        self.assertEqual(result["counts"]["accepted"],2)
        self.assertEqual(len(self.calls),2)
        self.assertEqual(result["counts"]["delivered"],0)
        self.assertEqual(service.preview("12F")["eligible_count"],0)
        new=self.post_body(preview)
        with self.assertRaises(Problem) as e:service.submit(new)
        self.assertEqual(e.exception.status,409)
        with sqlite3.connect(self.people) as c:
            self.assertEqual(c.execute("SELECT COUNT(*) FROM subscribers WHERE status='active'").fetchone()[0],0)
        self.store.event("mock-201000000001","delivered",int(time.time()))
        self.assertEqual(service.operation(body["request_id"])["counts"]["delivered"],1)

    def test_timeout_keeps_persistent_enrollment_reservation(self):
        def uncertain(*args):self.calls.append(args);raise TimeoutError()
        service=self.verified_service(uncertain);body=self.post_body(service.preview("12F"));service.submit(body)
        service.pool.shutdown(wait=True)
        result=service.operation(body["request_id"]);self.assertEqual(result["counts"]["unknown"],2)
        again=ClassReady(self.store,self.catalog,None)
        self.assertEqual(again.preview("12F")["eligible_count"],0)
        self.assertEqual(len(self.calls),2)
        self.assertEqual(again.operation(body["request_id"])["counts"]["unknown"],2)

    def test_pending_dispatch_rechecks_pause_and_enrollment(self):
        class Deferred:
            def submit(self,*args):pass
            def shutdown(self,**kwargs):pass
        service=self.verified_service();service.pool.shutdown(wait=True);service.pool=Deferred()
        body=self.post_body(service.preview("12F"));service.submit(body)
        with sqlite3.connect(self.people) as c:c.execute("INSERT INTO orbit_student_controls VALUES ('201000000001','blocked','now')")
        service.dispatch(body["request_id"])
        self.assertEqual(self.calls,[("12F","201000000002")])
        self.assertEqual(service.operation(body["request_id"])["counts"]["failed"],1)

    def test_history_scoping_pagination_search_sort_and_unknown_metadata(self):
        with sqlite3.connect(self.db) as c:
            c.executemany("INSERT INTO deliveries VALUES(?,?,?,?,?,?,?)",
              [("a","12F 26_10_26","201000000001","read","old-1","2026-10-26 10:00:00","classera-1"),
               ("b","12E 26_10_26","201000000001","accepted","old-2","2026-10-26 10:00:01","classera-2"),
               ("c","12F 25_10","201000000002","unknown",None,"2026-10-26 10:00:02","classera-1")])
        self.store.migrate();self.store.migrate()
        self.assertEqual(self.store.history({})["total"],3)
        page=self.store.history({"class_id":"12F","limit":"1","sort":"updated","direction":"asc"})
        self.assertEqual(page["total"],2);self.assertEqual(page["next_offset"],1)
        row=page["records"][0];self.assertIsNone(row["template"]);self.assertIsNone(row["created_at"])
        self.assertEqual(row["class_id"],"12F");self.assertEqual(row["report_date"],"2026-10-26")
        self.assertEqual(self.store.history({"search":"One"})["total"],1)
        self.assertEqual(self.store.history({"search":"%' OR 1=1 --"})["total"],0)
        self.assertEqual(self.store.history({"template":"classera_v9"})["total"],0)
        self.assertIsNone(report_date("12F 25_10",True))

    def test_statistics_use_latest_message_state_and_snapshot_denominator(self):
        run=self.store.begin("12F 26_10_26","12F",["201000000001","201000000002","201000000003"])
        first=self.store.attempt(run,"201000000001","classera_v9");self.store.result(first,"accepted","new-1")
        second=self.store.attempt(run,"201000000002","classera_no_ai");self.store.result(second,"failed")
        self.store.event("new-1","sent",1793010000);self.store.event("new-1","delivered",1793010001)
        self.store.event("new-1","read",1793010002);self.store.event("new-1","sent",1793010000)
        stats=self.store.statistics({"from":"2026-10-26","to":"2026-10-26"})
        self.assertEqual(stats["expected"],3);self.assertEqual(stats["attempts"],2)
        self.assertEqual(stats["counts"]["read"],1);self.assertEqual(stats["counts"]["delivered"],0)
        self.assertEqual(stats["counts"]["accepted"],0);self.assertEqual(stats["counts"]["failed"],1)
        self.assertEqual(stats["not_attempted"],1);self.assertEqual(stats["delivery_rate"],33.33)
        again=self.store.attempt(run,"201000000001","classera_v9");self.store.result(again,"delivered","new-3")
        self.assertEqual(self.store.statistics({"from":"2026-10-26","to":"2026-10-26"})["delivery_rate"],33.33)

    def test_legacy_stats_do_not_invent_expected_counts_and_force_run_is_not_snapshot(self):
        with sqlite3.connect(self.db) as c:c.execute("INSERT INTO deliveries VALUES('x','12F 26_10_26','201000000001','delivered','old','2026-10-26 10:00:00','classera-1')")
        self.store.migrate()
        self.store.begin("12F 26_10_26","12F",["201000000001"],forced=True)
        stats=self.store.statistics({"from":"2026-10-26","to":"2026-10-26"})
        self.assertIsNone(stats["expected"]);self.assertIsNone(stats["delivery_rate"])
        self.assertEqual(stats["counts"]["delivered"],1)
        self.assertEqual(stats["attempts"],1)

    def test_webhook_before_http_result_is_preserved_and_failed_unknown_are_not_delivered(self):
        run=self.store.begin("12F 26_10_26","12F",["201000000001"])
        identifier=self.store.attempt(run,"201000000001","classera_v9")
        self.store.event("race","read",1793010002)
        self.store.result(identifier,"accepted","race")
        self.assertEqual(self.store.history({})["records"][0]["status"],"read")
        self.assertEqual(self.store.statistics({"from":"2026-10-26","to":"2026-10-26"})["delivery_rate"],100)

    def test_same_title_in_different_year_keeps_separate_expected_targets(self):
        with patch("orbit_classera_monitor.report_date",return_value="2026-10-26"):
            self.store.begin("12F 26_10","12F",["201000000001"])
        with patch("orbit_classera_monitor.report_date",return_value="2027-10-26"):
            self.store.begin("12F 26_10","12F",["201000000001"])
        self.assertEqual(self.store.statistics({"from":"2027-10-26","to":"2027-10-26"})["expected"],1)

    def test_concurrent_different_uuid_cannot_reserve_same_enrollment(self):
        class Deferred:
            def submit(self,*args):pass
            def shutdown(self,**kwargs):pass
        service=self.verified_service();service.pool.shutdown(wait=True);service.pool=Deferred()
        preview=service.preview("12F")
        bodies=[self.post_body(preview),self.post_body(preview)]
        def submit(body):
            try:return service.submit(body)[1]
            except Problem as error:return error.status
        with ThreadPoolExecutor(max_workers=2) as workers:
            outcomes=list(workers.map(submit,bodies))
        self.assertEqual(sorted(outcomes),[202,409])
        with self.store.connect(True) as c:
            self.assertEqual(c.execute("SELECT COUNT(*) FROM orbit_class_ready_operations").fetchone()[0],1)
            self.assertEqual(c.execute("SELECT COUNT(*) FROM orbit_class_ready_recipients").fetchone()[0],2)
        self.assertEqual(self.calls,[])

    def test_malformed_database_phone_is_never_eligible(self):
        with sqlite3.connect(self.people) as c:
            c.execute("INSERT INTO subscribers VALUES ('bad-phone','Invalid','12F',NULL,'waiting_for_class','old','now')")
        preview=self.service.preview("12F")
        self.assertEqual(preview["waiting_count"],3)
        self.assertEqual(preview["eligible_count"],2)
        self.assertFalse(next(s for s in preview["students"] if s["phone"]=="bad-phone")["eligible"])
