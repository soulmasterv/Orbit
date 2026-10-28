import ast,sqlite3,tempfile,unittest
from pathlib import Path
from orbit_delivery_receipts import route_kapso_receipt,advance_legacy,replay_recorded_receipts,summary_status
from install_delivery_receipts import patch_webhook,patch_guard,patch_summary

class ReceiptTests(unittest.TestCase):
    def test_outbound_delivery_envelopes_never_enter_inbound_or_send(self):
        calls=[]
        for status in ["sent","delivered","read","failed"]:
            payload={"message":{"id":"mock-message","type":"text","kapso":{"direction":"outbound","status":status}}}
            self.assertTrue(route_kapso_receipt(payload,lambda *args,**kwargs:calls.append(args)))
        self.assertEqual([x[1] for x in calls],["sent","delivered","read","failed"])
        self.assertTrue(route_kapso_receipt({"message":{"id":"x","kapso":{"direction":"outbound","status":"pending"}}},lambda *a,**k:self.fail()))
    def test_inbound_and_raw_meta_are_not_misclassified_as_outbound_receipts(self):
        inbound={"message":{"id":"inbound","kapso":{"direction":"inbound","status":"delivered"}}}
        self.assertFalse(route_kapso_receipt(inbound,lambda *a,**k:self.fail()))
        self.assertFalse(route_kapso_receipt({"entry":[{"changes":[{"value":{"statuses":[{"id":"mock","status":"read"}]}}]}]},lambda *a,**k:self.fail()))
        self.assertTrue(route_kapso_receipt({"test":True,"message":{"kapso":{"direction":"inbound"}}},lambda *a,**k:self.fail()))
    def test_legacy_status_never_regresses_on_delayed_or_duplicate_events(self):
        c=sqlite3.connect(":memory:")
        c.execute("CREATE TABLE deliveries(status TEXT,message_id TEXT,updated_at TEXT)")
        c.execute("INSERT INTO deliveries VALUES('accepted','mock',NULL)")
        for status,expected in [("sent","sent"),("delivered","delivered"),("sent","delivered"),("read","read"),("delivered","read"),("failed","read"),("read","read")]:
            advance_legacy(c,"mock",status)
            self.assertEqual(c.execute("SELECT status FROM deliveries").fetchone()[0],expected)
        self.assertFalse(advance_legacy(c,"unmatched","read"))
    def test_failed_is_not_reopened_by_old_sent_receipt(self):
        c=sqlite3.connect(":memory:");c.execute("CREATE TABLE deliveries(status TEXT,message_id TEXT,updated_at TEXT)")
        c.execute("INSERT INTO deliveries VALUES('failed','mock',NULL)")
        self.assertFalse(advance_legacy(c,"mock","sent"))
        self.assertTrue(advance_legacy(c,"mock","delivered"))
        self.assertEqual(c.execute("SELECT status FROM deliveries").fetchone()[0],"delivered")
    def test_installer_preserves_raw_meta_handler_and_inbound_body(self):
        original='''def receive_webhook():
    data = request.get_json(silent=True) or {}
    kapso_message = data.get("message")
    process_inbound_or_raw_meta(data)
'''
        patched=patch_webhook(original)
        before=ast.parse(original).body[0];after=ast.parse(patched).body[0]
        self.assertEqual(ast.dump(ast.Module(body=before.body[1:],type_ignores=[])),
                         ast.dump(ast.Module(body=after.body[3:],type_ignores=[])))
        scope={"request":type("Request",(),{"get_json":lambda self,**k:{"message":{"id":"mock","kapso":{"direction":"outbound","status":"read"}}}})(),
               "jsonify":lambda x:x,"update_by_message_id":lambda *a,**k:None,
               "process_inbound_or_raw_meta":lambda x:self.fail("Outbound must never reply")}
        exec(patched,scope);self.assertEqual(scope["receive_webhook"]()[1],200)
    def test_recovery_replays_only_recorded_ids_and_never_executes_or_sends(self):
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp)/"events.log"
            payloads=[
                {"message":{"id":"known","kapso":{"direction":"outbound","status":"read"}}},
                {"message":{"id":"untracked","kapso":{"direction":"outbound","status":"read"}}},
                {"message":{"id":"known","kapso":{"direction":"inbound","status":"delivered"}}},
                {"entry":[{"changes":[{"value":{"statuses":[{"id":"known","status":"delivered","timestamp":"1793010000"}]}}]}]},
                {"test":True,"message":{"id":"known","kapso":{"direction":"outbound","status":"sent"}}}]
            path.write_text("\n".join(map(repr,payloads))+"\n__import__('os').system('must-not-execute')\n")
            calls=[];result=replay_recorded_receipts(path,{"known"},lambda *a,**k:calls.append((a,k)))
            self.assertEqual(len(calls),2);self.assertEqual(result["matched_message_count"],1)
            self.assertEqual(result["receipt_events"],{"read":1,"delivered":1})
    def test_installer_refuses_changed_guard(self):
        with self.assertRaises(RuntimeError):patch_guard("def update_by_message_id(a,b):\n    return False\n")

    def test_aggregate_badge_does_not_hide_delivered_or_read_behind_sent(self):
        self.assertEqual(summary_status(["sent","delivered","read"]),"Partially read")
        self.assertEqual(summary_status(["sent","delivered"]),"Partially delivered")
        self.assertEqual(summary_status(["read","read"]),"Read")
        self.assertEqual(summary_status(["delivered"]),"Delivered")
        self.assertEqual(summary_status(["failed","read"]),"Partially failed")
        self.assertEqual(summary_status([]),"No tracked sends")
    def test_summary_patch_changes_only_final_badge_selection(self):
        source="""def read_classera_delivery_status(classera_id):
    statuses = {'sent', 'read'}
    result = {'readCount': 1}
    labels = {'read': 'Read'}
    selected = 'sent'
    result['whatsappStatus'] = labels.get(selected, 'Unknown')
    return result
"""
        scope={};exec(patch_summary(source),scope)
        result=scope["read_classera_delivery_status"]("classera-1")
        self.assertEqual(result["whatsappStatus"],"Partially read");self.assertEqual(result["readCount"],1)
