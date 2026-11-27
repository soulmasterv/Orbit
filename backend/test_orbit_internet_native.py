import io,json,unittest
from flask import Flask
from orbit_internet_native import register,traffic_snapshot

class InternetNativeTests(unittest.TestCase):
    def setUp(self):
        self.calls=[];self.audio=[];app=Flask(__name__)
        def transport(path,method,body):self.calls.append((path,method,body));return {'version':1},200
        def audio(phone,event):self.audio.append((phone,event));return io.BytesIO(b'RIFF'+bytes(40)),200
        register(app,'fixture-owner',transport=transport,audio=audio,traffic=lambda:{'version':1,'interfaces':[]})
        self.client=app.test_client();self.auth={'Authorization':'Bearer fixture-owner'}
    def test_all_routes_require_native_bearer_and_reject_browser_origin(self):
        for path in ['/api/vnstat','/api/jarvis/internet/201000000001','/api/jarvis/internet/201000000001/recordings/ABCD1234']:
            self.assertEqual(self.client.get(path).status_code,401)
            self.assertEqual(self.client.get(path,headers={**self.auth,'Origin':'https://example.com'}).status_code,401)
        self.assertEqual(self.calls,[]);self.assertEqual(self.audio,[])
    def test_get_is_fixed_read_only_and_post_is_not_retried(self):
        path='/api/jarvis/internet/201000000001';self.assertEqual(self.client.get(path,headers=self.auth).status_code,200)
        self.assertEqual(self.calls,[('/internet/contact/201000000001','GET',None)])
        self.client.post(path,headers=self.auth,json={'action':'check','request_id':'fixture'})
        self.assertEqual(len(self.calls),2);self.assertEqual(self.calls[-1][1],'POST')
    def test_invalid_contacts_queries_bodies_and_recording_ids_are_rejected(self):
        for path in ['/api/jarvis/internet/abc','/api/jarvis/internet/201000000001?path=secret']:
            self.assertEqual(self.client.get(path,headers=self.auth).status_code,422)
        self.assertEqual(self.client.post('/api/jarvis/internet/201000000001',headers=self.auth,json=[]).status_code,422)
        self.assertEqual(self.client.get('/api/jarvis/internet/201000000001/recordings/not-an-event',headers=self.auth).status_code,404)
        self.assertEqual(self.calls,[]);self.assertEqual(self.audio,[])
    def test_recording_access_never_queues_and_has_private_headers(self):
        response=self.client.get('/api/jarvis/internet/201000000001/recordings/ABCD1234',headers=self.auth)
        self.assertEqual(response.status_code,200);self.assertEqual(response.data[:4],b'RIFF')
        self.assertEqual(response.headers['Cache-Control'],'no-store');self.assertIn('ABCD1234.wav',response.headers['Content-Disposition'])
        self.assertEqual(self.calls,[])
    def test_vnstat_does_not_sum_interfaces_or_fabricate_missing_counters(self):
        from types import SimpleNamespace
        fixture={'interfaces':[{'name':'eno1','updated':{'timestamp':100},'traffic':{'total':{'rx':0,'tx':10},'day':[{'date':{'year':2026,'month':11,'day':27},'rx':1,'tx':2}],'month':[]}}]}
        calls=[]
        def run(args,**kwargs):calls.append(args);return SimpleNamespace(stdout=json.dumps(fixture).encode())
        value=traffic_snapshot(run);self.assertEqual(value['interfaces'][0]['rx'],0);self.assertEqual(calls,[['vnstat','--json']])
        del fixture['interfaces'][0]['traffic']['total']['rx']
        with self.assertRaises(KeyError):traffic_snapshot(run)
    def test_vnstat_has_no_mutation_endpoint(self):
        self.assertEqual(self.client.post('/api/vnstat',headers=self.auth,json={}).status_code,405)
        self.assertEqual(self.calls,[])
