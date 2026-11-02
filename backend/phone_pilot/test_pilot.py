import gc,importlib.util,json,sqlite3,tempfile,time,unittest,uuid
from pathlib import Path
from flask import Flask
import orbit_phone_pilot as p
class Tests(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory();p.BROKER_DB=Path(self.tmp.name)/'broker.db';p.OPS_DB=Path(self.tmp.name)/'ops.db'
  with p.db() as c:c.executescript('CREATE TABLE alert_meta(id TEXT PRIMARY KEY,value TEXT); CREATE TABLE alert_events(sms TEXT,dispatched REAL);')
  p.runtime=lambda:{'adb':'connected','bluetooth':'connected','battery':70,'workers':{}}
  p.idle=lambda:True
  self.calls=[]
  p.run=lambda args,timeout=4:(self.calls.append(args) or type('Result',(),{'returncode':0,'stdout':''})())
  self.app=Flask(__name__);p.register(self.app,'test-token');self.client=self.app.test_client();self.headers={'Authorization':'Bearer test-token'}
 def tearDown(self):gc.collect();self.tmp.cleanup()
 def send(self,b):return self.client.post('/api/jarvis-phone/commands',json=b,headers=self.headers)
 def settings(self,**kw):return dict(request_id=str(uuid.uuid4()),kind='settings',revision=0,mode='web',forward_enabled=False,**kw)
 def test_legacy_client(self):
  with p.db() as c:
   ctl=p.reconcile(c,'sms',None,None);self.assertEqual(ctl['mode'],'sms');self.assertIsNone(p.meta(c,'orbit_phone_control'))
 def test_auth(self):self.assertEqual(self.client.get('/api/jarvis-phone/status').status_code,401)
 def test_sync(self):
  b=self.settings();self.assertEqual(self.send(b).json['status'],'pending_phone')
  with p.db() as c:
   ctl=p.reconcile(c,'sms',0,True);self.assertEqual(ctl['mode'],'web');self.assertFalse(ctl['forward_enabled'])
   p.reconcile(c,'web',1,False)
  self.assertTrue(self.client.get('/api/jarvis-phone/status',headers=self.headers).json['settings_applied'])
 def test_duplicate(self):
  b=self.settings();self.assertEqual(self.send(b).json,self.send(b).json)
  with p.db() as c:self.assertEqual(p.meta(c,'orbit_phone_control')['revision'],1)
 def test_conflict(self):
  self.send(self.settings());self.assertEqual(self.send(self.settings()).status_code,409)
 def test_local_sync(self):
  with p.db() as c:
   ctl=p.reconcile(c,'web',0,False);ctl=p.reconcile(c,'whatsapp',1,True)
   self.assertEqual(ctl['revision'],2);self.assertTrue(ctl['forward_enabled'])
 def test_untrusted_action(self):
  b=dict(request_id=str(uuid.uuid4()),kind='automation',target='shell',enabled=True)
  self.assertEqual(self.send(b).status_code,422);self.assertFalse(self.calls)
 def test_busy(self):
  p.idle=lambda:False
  self.assertEqual(self.send(dict(request_id=str(uuid.uuid4()),kind='automation',target='all',enabled=False)).status_code,409);self.assertFalse(self.calls)
 def test_automation_once(self):
  b=dict(request_id=str(uuid.uuid4()),kind='automation',target='outgoing',enabled=False)
  self.assertEqual(self.send(b).json['status'],'applied');self.send(b);self.assertEqual(len(self.calls),1)
 def test_origin_blocked(self):
  h=dict(self.headers,Origin='https://untrusted.example')
  self.assertEqual(self.client.post('/api/jarvis-phone/commands',json=self.settings(),headers=h).status_code,403)
if __name__=='__main__':unittest.main()
