import json,sqlite3,tempfile,time,unittest,uuid
from pathlib import Path
from unittest.mock import Mock
from flask import Flask
from classera_students import Directory,register
from classera_messaging import Messaging,Kapso,MessageProblem

class MessagingTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.path=Path(self.tmp.name)/"subscribers.db"
        with sqlite3.connect(self.path) as c:
            c.executescript("""CREATE TABLE subscribers(phone TEXT,name TEXT,class_name TEXT,ai_enabled INTEGER,status TEXT,joined_at TEXT,updated_at TEXT,PRIMARY KEY(phone,class_name));
            CREATE TABLE signup_sessions(phone TEXT PRIMARY KEY,step TEXT,name TEXT,class_name TEXT,updated_at TEXT);
            CREATE TABLE orbit_student_controls(phone TEXT PRIMARY KEY,activity_status TEXT,updated_at TEXT);""")
        self.directory=Directory(self.path);self.directory.migrate()
        self.phone="201000000001";self.calls=[]
        self.directory.create({"phone":self.phone,"name":"Student"})
        current=self.directory.get(self.phone)
        self.directory.save(self.phone,{"expected_revision":current["revision"],"subscriptions":[{"class_name":"12F","name":"Student","ai_enabled":1,"status":"active"}]})
        class Fake:
            def window(inner,phone,klass):return {"class_name":klass,"window_open":True,"seconds_left":5400,"last_inbound_at":int(time.time())-81000}
            def send(inner,phone,klass,text):self.calls.append((phone,klass,text));return "accepted","mock-message"
        self.provider=Fake();self.service=Messaging(self.directory,self.provider)
    def tearDown(self):self.tmp.cleanup()
    def body(self):return {"request_id":str(uuid.uuid4()),"class_name":"12F","text":"Only a fake send"}
    def test_profile_creation_name_save_and_disabled_are_independent(self):
        phone="201000000002";created=self.directory.create({"phone":phone,"name":"New Student"})
        self.assertEqual(created["subscriptions"],[])
        self.assertIn(phone,[x["phone"] for x in self.directory.listing()["students"]])
        renamed=self.directory.rename(phone,{"expected_revision":created["revision"],"name":"Renamed"})
        self.assertEqual(renamed["profile_name"],"Renamed")
        saved=self.directory.save(phone,{"expected_revision":renamed["revision"],"subscriptions":[{"class_name":"12F","name":"Renamed","ai_enabled":None,"status":"disabled"}]})
        self.assertEqual(saved["subscriptions"][0]["status"],"disabled")
        self.assertNotIn(phone,self.directory.recipients("classera-1"))
        self.assertEqual(self.calls,[])
    def test_send_once_and_replay_does_not_dispatch_again(self):
        body=self.body();first=self.service.submit(self.phone,body)
        self.assertEqual(first["status"],"accepted")
        self.assertEqual(self.service.submit(self.phone,body),first);self.assertEqual(len(self.calls),1)
        with self.assertRaises(MessageProblem):self.service.submit(self.phone,{**body,"text":"Changed"})
        self.assertEqual(len(self.calls),1)
    def test_expired_suspended_disabled_and_cross_class_are_not_sent(self):
        self.provider.window=lambda p,k:{"class_name":k,"window_open":False,"seconds_left":0,"last_inbound_at":int(time.time())-86400}
        with self.assertRaises(MessageProblem):self.service.submit(self.phone,self.body())
        for status in ["suspended","blocked"]:
            current=self.directory.get(self.phone)
            self.directory.manage(self.phone,{"expected_revision":current["revision"],"activity_status":status})
            with self.assertRaises(MessageProblem):self.service.submit(self.phone,self.body())
        self.assertEqual(self.calls,[])
    def test_unknown_outcome_is_persistent_and_never_retried(self):
        def fail(*args):self.calls.append(args);raise TimeoutError()
        self.provider.send=fail;body=self.body()
        self.assertEqual(self.service.submit(self.phone,body)["status"],"unknown")
        other=Messaging(self.directory,self.provider)
        self.assertEqual(other.submit(self.phone,body)["status"],"unknown")
        self.assertEqual(len(self.calls),1)
    def test_validation_and_owner_auth(self):
        for b in [{}, {**self.body(),"text":""},{**self.body(),"text":"x"*4097},{**self.body(),"class_name":"12D"},{**self.body(),"request_id":"bad"}]:
            with self.assertRaises(MessageProblem):self.service.submit(self.phone,b)
        app=Flask(__name__);register(app,"owner-placeholder",self.directory)
        client=app.test_client();url="/api/classera-students/"+self.phone+"/messaging"
        self.assertEqual(client.get(url).status_code,401)
        self.assertEqual(client.post(url,json=self.body(),headers={"X-API-Key":"owner-placeholder"}).status_code,401)
        self.assertEqual(client.get(url,headers={"Authorization":"Bearer owner-placeholder","Origin":"https://example.invalid"}).status_code,403)
        self.assertEqual(self.calls,[])
    def test_provider_reads_exact_recipient_and_number_and_never_follows_redirects(self):
        http=Mock();provider=Kapso(http);provider.settings=lambda k:("placeholder","123")
        http.get.return_value.status_code=200
        http.get.return_value.json.return_value={"data":[{"phone_number":"+"+self.phone,"phone_number_id":"123","kapso":{"last_inbound_at":time.strftime("%Y-%m-%dT%H:%M:%SZ",time.gmtime(time.time()-3600))}},
            {"phone_number":"201000000999","phone_number_id":"123","kapso":{"last_inbound_at":"2099-01-01T00:00:00Z"}}]}
        window=provider.window(self.phone,"12F")
        self.assertTrue(window["window_open"]);self.assertLessEqual(window["seconds_left"],82800)
        self.assertFalse(http.get.call_args.kwargs["allow_redirects"])
        self.assertEqual(http.get.call_args.kwargs["params"]["phone_number"],self.phone)
        http.get.return_value.status_code=302
        with self.assertRaises(MessageProblem):provider.window(self.phone,"12F")
        http.post.assert_not_called()
    def test_provider_post_exact_plaintext_payload_no_retry_or_redirect(self):
        http=Mock();provider=Kapso(http);provider.settings=lambda k:("placeholder","123")
        http.post.return_value.status_code=200;http.post.return_value.json.return_value={"messages":[{"id":"mock"}]}
        self.assertEqual(provider.send(self.phone,"12F","Hello"),("accepted","mock"))
        self.assertEqual(http.post.call_count,1)
        self.assertEqual(http.post.call_args.kwargs["json"]["text"],{"body":"Hello","preview_url":False})
        self.assertFalse(http.post.call_args.kwargs["allow_redirects"])
        self.assertEqual(http.post.call_args.kwargs["json"]["to"],self.phone)
    def test_rename_preserves_unknown_classes_and_stale_revision_is_rejected(self):
        with sqlite3.connect(self.path) as c:
            c.execute("INSERT INTO subscribers VALUES(?,?,?,NULL,'active','old','old')",(self.phone,"Legacy","OLD"))
        record=self.directory.get(self.phone)
        renamed=self.directory.rename(self.phone,{"expected_revision":record["revision"],"name":"Updated"})
        self.assertEqual(next(r["name"] for r in renamed["subscriptions"] if r["class_name"]=="OLD"),"Legacy")
        from classera_students import Conflict
        with self.assertRaises(Conflict):self.directory.rename(self.phone,{"expected_revision":record["revision"],"name":"Stale"})

    def test_same_uuid_race_has_only_one_provider_dispatch(self):
        from concurrent.futures import ThreadPoolExecutor
        body=self.body()
        with ThreadPoolExecutor(max_workers=2) as pool:
            results=list(pool.map(lambda _:self.service.submit(self.phone,body),[1,2]))
        self.assertEqual(len(self.calls),1)
        self.assertEqual({r["id"] for r in results},{body["request_id"]})
    def test_disabled_class_does_not_remove_profile_or_other_class(self):
        current=self.directory.get(self.phone)
        rows=current["subscriptions"]
        rows=[{k:r[k] for k in ("class_name","name","ai_enabled","status")} for r in rows]
        rows[0]["status"]="disabled";rows[0]["ai_enabled"]=None
        rows.append({"class_name":"12E","name":"Student","ai_enabled":0,"status":"active"})
        saved=self.directory.save(self.phone,{"expected_revision":current["revision"],"subscriptions":rows})
        self.assertEqual(saved["profile_name"],"Student")
        self.assertEqual(self.directory.recipients("classera-1"),[])
        self.assertEqual(self.directory.recipients("classera-2"),[self.phone])
        with self.assertRaises(MessageProblem):self.service.submit(self.phone,self.body())
        self.assertEqual(self.calls,[])
