import json
import sqlite3
import unittest
from companion_health import accept

class HealthTests(unittest.TestCase):
    def setUp(self):
        self.db = sqlite3.connect(':memory:')
        self.db.executescript('CREATE TABLE alert_meta(id TEXT PRIMARY KEY,value TEXT); CREATE TABLE alert_events(id TEXT PRIMARY KEY,kind TEXT,body TEXT,created REAL,expires REAL,sms TEXT);')
    def tearDown(self):
        self.db.close()
    def diagnostic(self, sms=True, sim=True, enabled=True):
        return dict(version=1,sms_permissions=sms,sim_ready=sim,forward_enabled=enabled)
    def count(self):
        return self.db.execute('SELECT count(*) FROM alert_events').fetchone()[0]
    def test_missing_permissions_debounced_and_no_repeated_alert(self):
        for now in (100,110,120): accept(self.db,self.diagnostic(sms=False),'web',now)
        self.assertEqual(self.count(),0)
        accept(self.db,self.diagnostic(sms=False),'web',131)
        accept(self.db,self.diagnostic(sms=False),'web',180)
        self.assertEqual(self.count(),1)
    def test_recovery_requires_stability(self):
        accept(self.db,self.diagnostic(sim=False),'web',100)
        accept(self.db,self.diagnostic(sim=False),'web',131)
        accept(self.db,self.diagnostic(),'web',140)
        self.assertEqual(self.count(),1)
        accept(self.db,self.diagnostic(),'web',171)
        self.assertEqual(self.count(),2)
    def test_old_companion_and_disabled_forwarding(self):
        accept(self.db,None,'web',100)
        accept(self.db,self.diagnostic(sms=False,sim=False,enabled=False),'web',100)
        accept(self.db,self.diagnostic(sms=False,sim=False,enabled=False),'web',200)
        self.assertEqual(self.count(),0)
    def test_sms_alerts_still_require_permissions(self):
        accept(self.db,self.diagnostic(sms=False,enabled=False),'sms',100)
        accept(self.db,self.diagnostic(sms=False,enabled=False),'sms',131)
        self.assertEqual(self.count(),1)
    def test_invalid_payload_does_not_change_state(self):
        with self.assertRaises(ValueError): accept(self.db,dict(version=1,sms_permissions='true'),'web',100)
        self.assertEqual(self.db.execute('SELECT count(*) FROM alert_meta').fetchone()[0],0)
if __name__=='__main__': unittest.main()
