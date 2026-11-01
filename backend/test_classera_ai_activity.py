import ast
import copy
import sqlite3
import tempfile
import unittest
from pathlib import Path
from classera_ai_activity import migrate, observe_button, evidence
from install_ai_button_audit import patch_webhook


class AIButtonActivityTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.path = Path(self.temp.name) / 'delivery.db'
        self.connection = sqlite3.connect(self.path)
        migrate(self.connection, now=1000); self.connection.commit()
        self.message = {'type':'button','from':'201000000001','id':'inbound-1','timestamp':'1200',
                        'button':{'payload':'Get AI Analysis'},'context':{'id':'outbound-1'}}
        self.attempt = {'phone':'201000000001','message_id':'outbound-1','historical':False,'created_at':1100}

    def tearDown(self):
        self.connection.close(); self.temp.cleanup()

    def observe(self, message=None):
        return observe_button(self.message if message is None else message, path=self.path, now=1300)

    def test_exact_click_records_request_independent_of_analysis_reply(self):
        self.assertTrue(self.observe())
        self.assertEqual(evidence(self.connection,self.attempt),{'status':'requested','requested_at':1200})

    def test_duplicate_is_idempotent_and_changed_replay_does_not_reassign(self):
        self.assertTrue(self.observe()); self.assertTrue(self.observe())
        changed=copy.deepcopy(self.message); changed['from']='201000000002'
        self.assertFalse(self.observe(changed))
        self.assertEqual(self.connection.execute('SELECT COUNT(*) FROM orbit_ai_button_events').fetchone()[0],1)

    def test_phone_parent_and_repeat_report_attempts_do_not_cross_match(self):
        self.observe()
        for changed in [{'phone':'201000000002'},{'message_id':'other-class-message'},{'message_id':'retry-report-message'}]:
            self.assertEqual(evidence(self.connection,{**self.attempt,**changed})['status'],'not_recorded')

    def test_early_click_can_bind_after_outbound_attempt_is_recorded(self):
        self.observe()
        # Recorder does not guess latest delivery or require it to be bound yet.
        self.assertEqual(evidence(self.connection,self.attempt)['status'],'requested')

    def test_text_synthetic_and_other_buttons_are_not_ai_button_presses(self):
        for updates in [{'type':'text'},{'button':{'payload':'View Detailed Report'}},
                        {'button':{'payload':'Opt in'}},{'context':{}},{'type':'interactive'}]:
            self.assertFalse(self.observe({**self.message,**updates}))
        self.assertEqual(self.connection.execute('SELECT COUNT(*) FROM orbit_ai_button_events').fetchone()[0],0)

    def test_invalid_identity_and_time_fail_closed_without_raw_logging(self):
        for updates in [{'from':'+201000000001'},{'id':''},{'id':'x'*513},{'timestamp':True},
                        {'timestamp':'n/a'},{'timestamp':'0'},{'timestamp':'1601'},{'timestamp':-1}]:
            self.assertFalse(self.observe({**self.message,**updates}))

    def test_missing_database_or_migration_is_unknown_and_never_created(self):
        missing=Path(self.temp.name)/'absent.db'
        self.assertFalse(observe_button(self.message,path=missing,now=1300)); self.assertFalse(missing.exists())
        with sqlite3.connect(':memory:') as empty:
            before=empty.total_changes
            self.assertEqual(evidence(empty,self.attempt)['status'],'unknown')
            self.assertEqual(empty.total_changes,before)

    def test_legacy_missing_time_and_pre_tracking_records_stay_unknown(self):
        for changes in [{'historical':True},{'created_at':None},{'created_at':999}]:
            self.assertEqual(evidence(self.connection,{**self.attempt,**changes})['status'],'unknown')
        self.assertEqual(evidence(self.connection,self.attempt)['status'],'not_recorded')

    def test_migration_preserves_coverage_and_history_reads_do_not_write(self):
        migrate(self.connection,now=2000)
        self.assertEqual(self.connection.execute('SELECT started_at FROM orbit_ai_button_tracking').fetchone()[0],1000)
        before=self.connection.total_changes
        evidence(self.connection,self.attempt)
        self.assertEqual(self.connection.total_changes,before)

    def test_patch_only_real_inbound_call_sites_preserves_shared_handler(self):
        original='''def handle_ai_request(message, phone_number_id):
    handle_ai_button(message, phone_number_id)
def receive_webhook():
    if message_type == "button":
        handle_ai_button(kapso_message, phone_number_id)
    if message.get("type") == "button":
        handle_ai_button(message, phone_number_id)
'''
        patched=patch_webhook(original)
        self.assertEqual(patched.count('from classera_ai_activity import'),2)
        tree=ast.parse(patched)
        self.assertEqual(ast.dump(tree.body[0]),ast.dump(ast.parse(original).body[0]))
        with self.assertRaises(ValueError):patch_webhook(patched)
        with self.assertRaises(ValueError):patch_webhook(original.replace('handle_ai_button(message, phone_number_id)','other(message, phone_number_id)'))
