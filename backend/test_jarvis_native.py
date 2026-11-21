import unittest
from flask import Flask
from orbit_jarvis_native import register

class NativeBridgeTests(unittest.TestCase):
    def setUp(self):
        self.app = Flask(__name__)
        self.calls = []
        def transport(path, method, body):
            self.calls.append((path, method, body))
            return {'status': 'unknown'}, 200
        register(self.app, 'fixture-owner', transport)
        self.client = self.app.test_client()
        self.auth = {'Authorization': 'Bearer fixture-owner'}
    def test_auth_and_browser_origin_rejected(self):
        self.assertEqual(self.client.get('/api/jarvis/whatsapp').status_code, 401)
        self.assertEqual(self.client.post('/api/jarvis/whatsapp/send', headers={**self.auth, 'Origin':'https://example.com'}, json={}).status_code, 401)
        self.assertFalse(self.calls)
    def test_authenticated_paths_are_fixed(self):
        self.assertEqual(self.client.get('/api/jarvis/whatsapp', headers=self.auth).status_code, 200)
        self.assertEqual(self.calls[0], ('/inbox', 'GET', None))
        self.client.post('/api/jarvis/fun-call', headers=self.auth, json={'request_id':'fixture'})
        self.assertEqual(self.calls[-1][0], '/fun-call')
    def test_invalid_recipients_and_queries_rejected(self):
        for p in ['abc', '123', '１２３４５６７８']:
            self.assertEqual(self.client.get('/api/jarvis/whatsapp/chats/'+p, headers=self.auth).status_code, 400)
        self.assertEqual(self.client.get('/api/jarvis/whatsapp/chats/201000000001?before=http://evil', headers=self.auth).status_code, 400)
        self.assertFalse(self.calls)
    def test_post_not_retried_and_uncertainty_preserved(self):
        self.client.post('/api/jarvis/whatsapp/send', headers=self.auth, json={'destination':'201000000001','text':'Fixture','request_id':'fixture'})
        self.assertEqual(len(self.calls),1)
        self.assertEqual(self.calls[0][0],'/inbox/send')
    def test_bad_or_oversized_json_rejected(self):
        self.assertEqual(self.client.post('/api/jarvis/whatsapp/send', headers=self.auth, json=[]).status_code, 400)
        self.assertEqual(self.client.post('/api/jarvis/whatsapp/send', headers=self.auth, json={'text':'x'*60000}).status_code, 400)
        self.assertFalse(self.calls)

if __name__ == '__main__':
    unittest.main()
