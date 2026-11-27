import sqlite3
import unittest
import phone_notifications as n


class IncidentTests(unittest.TestCase):
    def setUp(self):
        self.c=sqlite3.connect(':memory:');self.c.row_factory=sqlite3.Row
        self.c.executescript('''CREATE TABLE alert_meta(id TEXT PRIMARY KEY,value TEXT);
            CREATE TABLE alert_events(id TEXT PRIMARY KEY,kind TEXT,body TEXT,created REAL,expires REAL,
            sms TEXT DEFAULT 'pending',push TEXT DEFAULT 'pending',dispatched REAL,next_push REAL DEFAULT 0);''')
        n.init(self.c)
    def tearDown(self):self.c.close()
    def event(self,ident,kind,at):
        self.c.execute('INSERT INTO alert_events(id,kind,body,created,expires) VALUES (?,?,?,?,?)',(ident,kind,'Orbit test',at,at+300))
    def route(self,ident):return n.route(self.c,ident)
    def test_recovery_waits_for_error_receipt(self):
        self.event('e','health',100);self.event('r','health_recovery',101);n.prepare(self.c,102)
        self.assertIsNone(self.route('r')['target'])
        self.c.execute("UPDATE alert_events SET push='accepted' WHERE id='e'");n.prepare(self.c,103)
        self.assertEqual(self.route('r')['target'],'web');self.assertEqual(self.route('r')['status'],'pending')
    def test_sms_receipt_pins_incident_even_when_choice_changes(self):
        n.settings(self.c,'sms',False);self.event('e','health',100);n.prepare(self.c,101)
        self.c.execute("UPDATE alert_events SET sms='submitted',dispatched=101 WHERE id='e'")
        n.settings(self.c,'web',False);self.event('r','health_recovery',102);n.prepare(self.c,103)
        self.assertEqual(self.route('r')['chosen'],'sms');self.assertEqual(self.route('r')['target'],'sms')
        self.assertEqual(self.route('e')['incident'],self.route('r')['incident'])
    def test_fallback_off_blocks_both_missing_sim_and_failed_sms(self):
        n.settings(self.c,'sms',False);n.put(self.c,'orbit_companion_diagnostics',{'sim_ready':False})
        self.event('e','companion_health',100);n.prepare(self.c,101)
        self.assertIsNone(self.route('e')['target']);self.assertEqual(self.route('e')['status'],'unavailable')
    def test_fallback_receipt_moves_recovery_to_orbit(self):
        n.settings(self.c,'sms',True);self.event('e','health',100);n.prepare(self.c,101)
        self.c.execute("UPDATE alert_events SET sms='failed',dispatched=101 WHERE id='e'")
        self.event('r','health_recovery',102);n.prepare(self.c,103)
        self.assertEqual(self.route('e')['target'],'web');self.assertIsNone(self.route('r')['target'])
        self.c.execute("UPDATE alert_events SET push='accepted' WHERE id='e'");n.prepare(self.c,104)
        self.assertEqual(self.route('r')['target'],'web')
    def test_duplicate_error_and_recovery_keep_incident_and_suppress(self):
        self.event('e','health',100);self.event('duplicate','health',101);n.prepare(self.c,102)
        self.assertEqual(self.route('duplicate')['status'],'suppressed')
        self.event('r','health_recovery',103);self.event('r2','health_recovery',104);n.prepare(self.c,105)
        self.assertEqual(self.route('r2')['status'],'suppressed')
        self.assertEqual(self.route('r2')['incident'],self.route('e')['incident'])
    def test_orphan_recovery_and_expired_error_do_not_notify(self):
        self.event('r','health_recovery',100);n.prepare(self.c,101)
        self.assertEqual(self.route('r')['status'],'suppressed')
        self.event('e','companion_health',102);n.prepare(self.c,500)
        self.assertIsNone(self.route('e')['target'])
    def test_incoming_call_uses_phone_delivery(self):
        n.settings(self.c,'sms',False);self.event('call','call',100);n.prepare(self.c,101)
        self.assertEqual(self.route('call')['target'],'sms');self.assertEqual(self.route('call')['category'],'incoming_call')
    def test_sms_outage_never_replays_offline_event(self):
        n.settings(self.c,'sms',False);self.event('e','companion_offline',100);n.prepare(self.c,101)
        self.assertIsNone(self.route('e')['target']);n.prepare(self.c,102)
        self.assertIsNone(self.route('e')['target'])
    def test_history_does_not_claim_receipt_before_send(self):
        self.event('e','health',100);n.prepare(self.c,101)
        row=n.history(self.c,101)[0]
        self.assertIsNone(row['actual']);self.assertEqual(row['chosen'],'web')
        self.assertIn('incident',row);self.assertIn('category',row)
    def test_switch_off_cancels_unsent_fallback(self):
        n.settings(self.c,'sms',True);self.event('e','health',100);n.prepare(self.c,101)
        self.c.execute("UPDATE alert_events SET sms='failed',dispatched=101 WHERE id='e'");n.prepare(self.c,102)
        self.assertEqual(self.route('e')['target'],'web')
        n.settings(self.c,'sms',False);n.prepare(self.c,103)
        self.assertIsNone(self.route('e')['target'])


if __name__=='__main__':unittest.main()
