import importlib.util
import json
from pathlib import Path
import sqlite3
import sys
import tempfile
import types
import unittest
from unittest.mock import patch

import phone_notifications as routing

HERE=Path(__file__).parent
import os
source=os.getenv('ORBIT_PHONE_BROKER_SOURCE')
if not source: raise unittest.SkipTest('Set ORBIT_PHONE_BROKER_SOURCE to test the external broker integration')
from patch_broker import patch as patch_source
broker=types.ModuleType('test_broker');broker.__file__=source
exec(compile(patch_source(Path(source).read_text(encoding='utf-8')),source,'exec'),broker.__dict__)


class RoutingTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory()
        broker.DB=Path(self.temp.name)/'alerts.db'
        broker.ROOT=Path(self.temp.name)
        broker.init()
        self.sent=[]
        self.device='11111111-1111-4111-8111-111111111111'
        self.modules=patch.dict(sys.modules,{
            'orbit_phone_pilot':types.SimpleNamespace(reconcile=lambda c,mode,revision,forward:{'mode':mode or 'web','revision':0,'forward_enabled':bool(forward)}),
            'school_webpush':types.SimpleNamespace(key_fingerprint=lambda:'test',validate_subscription=lambda s:s,deliver=self.sender),
        });self.modules.start()
        broker.config=lambda:{'web_device_ids':['test']}
        broker.whatsapp_ready=lambda:False
        with sqlite3.connect(broker.ROOT/'school.db') as c:
            c.execute('CREATE TABLE web_devices(id TEXT, enabled INTEGER, expires_at REAL, key_fp TEXT, subscription TEXT)')
            c.execute("INSERT INTO web_devices VALUES ('test',1,9999999999,'test','{}')")
        c.close()
    def tearDown(self):
        self.modules.stop();self.temp.cleanup()
    def sender(self,subscription,payload):
        self.sent.append(payload)
        return 201,''
    def settings(self,channel='web',fallback=True):
        with broker.connect() as c:routing.settings(c,channel,fallback)
    def event(self,kind='health',at=100):
        return broker.emit(kind,'Orbit test '+kind,now=at)
    def poll(self,now=101,acks=None,delivery=None,fallback=None):
        return broker.poll(self.device,acks or [],now=now,mode='web',phone_delivery=delivery,phone_fallback=fallback)
    def row(self,ident):
        with broker.connect() as c:return dict(routing.route(c,ident))
    def push(self,now=102):broker.push_fallback(now=now,sender=self.sender)
    def test_orbit_calls_ignore_legacy_sms_mode(self):
        ident=self.event('call')
        result=broker.poll(self.device,[],now=101,mode='sms',phone_delivery='web')
        self.assertEqual(result['jobs'],[]);self.push()
        self.assertEqual(self.row(ident)['actual'],'web')
    def test_sms_calls_ignore_legacy_web_mode(self):
        self.settings('sms',False);ident=self.event('call')
        jobs=self.poll()['jobs'];self.assertEqual(jobs[0]['id'],ident)
        self.assertTrue(jobs[0]['phone_alert']);self.push(150)
        self.assertEqual(len(self.sent),0)
    def test_fallback_disabled_never_pushes_failed_sms(self):
        self.settings('sms',False);ident=self.event();self.poll()
        self.poll(102,[{'id':ident,'status':'failed'}]);self.push(140)
        self.assertEqual(self.sent,[]);self.assertIsNone(self.row(ident)['actual'])
    def test_switch_off_cancels_unsent_fallback_on_active_incident(self):
        self.settings('sms',True);ident=self.event();self.poll()
        self.poll(102,[{'id':ident,'status':'failed'}],fallback=False);self.push(140)
        self.assertEqual(self.sent,[])
    def test_failed_error_and_recovery_move_together_to_orbit(self):
        self.settings('sms',True);error=self.event();self.poll()
        recovery=self.event('health_recovery',102)
        self.poll(103,[{'id':error,'status':'failed'}]);self.push(104);self.push(105)
        self.assertEqual(len(self.sent),2)
        a,b=self.row(error),self.row(recovery)
        self.assertEqual(a['incident'],b['incident']);self.assertEqual(a['actual'],b['actual']);self.assertEqual(b['actual'],'web')
        self.assertEqual(b['chosen'],'sms')
    def test_unsent_error_never_allows_recovery(self):
        self.settings('sms',False);error=self.event();recovery=self.event('health_recovery',101)
        self.assertEqual([j['id'] for j in self.poll(102)['jobs']],[error]);self.push(150)
        self.assertEqual(self.row(recovery)['status'],'waiting_for_error');self.assertEqual(self.sent,[])
    def test_orphan_recovery_is_suppressed(self):
        recovery=self.event('health_recovery');self.poll();self.push()
        self.assertEqual(self.row(recovery)['status'],'suppressed');self.assertEqual(self.sent,[])
    def test_choice_change_keeps_active_incident_on_sms(self):
        self.settings('sms',False);error=self.event();self.poll()
        self.poll(102,[{'id':error,'status':'submitted'}],delivery='web')
        recovery=self.event('health_recovery',103)
        self.assertEqual(self.poll(104)['jobs'][0]['id'],recovery)
        self.assertEqual(self.row(recovery)['chosen'],'sms')
        self.assertEqual(self.row(recovery)['target'],'sms')
    def test_failed_recovery_fallback_sends_error_on_orbit_first(self):
        self.settings('sms',True);error=self.event();self.poll()
        self.poll(102,[{'id':error,'status':'submitted'}])
        recovery=self.event('health_recovery',103);self.poll(104)
        self.poll(105,[{'id':recovery,'status':'failed'}]);self.push(106);self.push(107)
        self.assertEqual([p['event_id'] for p in self.sent],[error,recovery])
        self.assertEqual(self.row(error)['actual'],self.row(recovery)['actual'])
    def test_unavailable_sim_no_silent_fallback(self):
        self.settings('sms',False)
        with broker.connect() as c:routing.put(c,'orbit_companion_diagnostics',{'sim_ready':False})
        ident=self.event('companion_health');self.assertEqual(self.poll()['jobs'],[]);self.push()
        self.assertEqual(self.sent,[]);self.assertEqual(self.row(ident)['status'],'unavailable')
    def test_offline_sms_blocked_and_not_replayed_after_recovery(self):
        self.settings('sms',False);error=self.event('companion_offline');self.push(101)
        self.assertEqual(self.poll(102)['jobs'],[]);self.assertEqual(self.row(error)['status'],'unavailable')
        self.event('companion_recovery',103);self.assertEqual(self.poll(104)['jobs'],[]);self.push(105)
        self.assertEqual(self.sent,[])
    def test_repeated_error_suppressed(self):
        first=self.event();second=self.event(at=101);self.poll(102);self.push(103)
        self.assertEqual(self.row(first)['incident'],self.row(second)['incident']);self.assertEqual(self.row(second)['status'],'suppressed')
        self.assertEqual(len(self.sent),1)
    def test_history_survives_event_cleanup_and_restart(self):
        ident=self.event('call');self.poll();self.push();self.poll(103)
        with broker.connect() as c:c.execute('DELETE FROM alert_events')
        broker.init()
        result=self.poll(104)['notification_history'][0]
        self.assertEqual(result['event_id'],ident);self.assertEqual(result['actual'],'web')
        self.assertEqual(result['status'],'accepted')
    def test_invalid_settings_do_not_mutate(self):
        with self.assertRaises(ValueError):self.poll(delivery='whatsapp')
        with broker.connect() as c:self.assertEqual(routing.settings(c),('web',True))
    def test_existing_health_cooldowns_preserved(self):
        events=[];h=broker.Health()
        send=lambda *args:events.append(args)
        h.observe(['ADB unavailable'],100,send);h.observe(['ADB unavailable'],189,send)
        self.assertEqual(events,[]);h.observe(['ADB unavailable'],190,send)
        h.observe([],200,send);h.observe([],379,send);self.assertEqual(len(events),1)
        h.observe([],380,send);self.assertEqual(events[1][0],'health_recovery')
        h.observe(['ADB unavailable'],390,send);h.observe(['ADB unavailable'],480,send)
        self.assertEqual(len(events),2)


if __name__=='__main__':unittest.main()
