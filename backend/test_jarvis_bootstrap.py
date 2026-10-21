import base64
from email.message import Message
import json
import unittest
from orbit_jarvis_bootstrap import Broker, Failure, NoRedirect, ORIGIN, PRIVATE

NOW=1792400000
REQ=dict(version=1,installation_id='12345678-1234-1234-1234-123456789abc',nonce='n'*24)
def cfg():return dict(cf_client_id='fixture-id',cf_client_secret='fixture-not-a-real-secret',cf_token_expires_at=NOW+3600,bridge_key='a'*64)
class Fake:
    def __init__(self):self.calls=[];self.revoked=False;self.strict=False;self.fail_web=False;self.expiry=NOW+800
    def fetch(self,url,method='GET',headers=None,body=None):
        headers=headers or {};self.calls.append((url,method,headers));h=Message()
        if url==PRIVATE:
            if method=='DELETE':self.revoked=True;return 200,h,b'{}'
            payload=json.loads(body)
            return 200,h,json.dumps(dict(version=1,nonce=payload['nonce'],entry_url=ORIGIN+'/',expires_at=NOW+900,cookie=dict(name='jarvis',value='b'*64,domain='jarvis.labbing.space',path='/',secure=True,http_only=True))).encode()
        if 'CF-Access-Client-Secret' in headers:
            if not self.strict:
                claim=base64.urlsafe_b64encode(json.dumps(dict(exp=self.expiry)).encode()).decode().rstrip('=')
                h.add_header('Set-Cookie','CF_Authorization=e30.'+claim+'.fixture; Path=/; Secure; HttpOnly')
            return 200,h,b'<html></html>'
        if self.fail_web:raise Failure()
        self.assert_cookie(headers)
        if url.endswith('/session'):return 200,h,b'{"csrf":"fixture"}'
        if url.endswith('/memory'):return (404 if getattr(self,'memory_missing',False) else 200),h,b'{"items":[]}'
        h['Content-Type']='text/html' if url==ORIGIN+'/' else 'text/javascript'
        return 200,h,b'fixture'
    def assert_cookie(self,headers):
        assert 'CF-Access-Client-Secret' not in headers and 'CF-Access-Client-Id' not in headers
        assert 'Authorization' not in headers
        assert 'CF_Authorization=' in headers.get('Cookie','')
    def websocket(self,cookie):
        assert 'jarvis=' in cookie
        if self.fail_web:raise Failure()
class Tests(unittest.TestCase):
    def broker(self,transport=None,config=cfg):return Broker('fixture-owner',config,transport or Fake(),lambda:NOW)
    def test_auth_before_configuration(self):
        b=self.broker(config=lambda:(_ for _ in ()).throw(AssertionError('must not load')))
        with self.assertRaises(Failure) as caught:b.handle('Bearer wrong',REQ)
        self.assertEqual(caught.exception.status,401)
    def test_contract_and_secret_scope(self):
        t=Fake();r=self.broker(t).handle('Bearer fixture-owner',REQ)
        self.assertEqual(r['nonce'],REQ['nonce']);self.assertEqual(r['expires_at'],NOW+800)
        self.assertEqual([c['name'] for c in r['cookies']],['CF_Authorization','jarvis'])
        self.assertTrue(all(c['secure'] and c['http_only'] for c in r['cookies']))
        self.assertNotIn('cf_client_secret',json.dumps(r))
        machine=[c for c in t.calls if 'CF-Access-Client-Secret' in c[2]]
        self.assertEqual(len(machine),1);self.assertEqual(machine[0][0],ORIGIN+'/')
    def test_strict_or_missing_cookie_fails_closed(self):
        t=Fake();t.strict=True
        with self.assertRaises(Failure):self.broker(t).handle('Bearer fixture-owner',REQ)
        self.assertFalse(any(url==PRIVATE for url,_,_ in t.calls))
    def test_overlong_cookie_lifetime_rejected(self):
        t=Fake();t.expiry=NOW+1800
        with self.assertRaises(Failure):self.broker(t).handle('Bearer fixture-owner',REQ)
    def test_nonce_replay_and_rate_limits(self):
        b=self.broker();b.handle('Bearer fixture-owner',REQ)
        with self.assertRaises(Failure) as c:b.handle('Bearer fixture-owner',REQ)
        self.assertEqual(c.exception.status,409)
        for i in range(5):b.handle('Bearer fixture-owner',dict(REQ,nonce=str(i)*24))
        with self.assertRaises(Failure) as c:b.handle('Bearer fixture-owner',dict(REQ,nonce='z'*24))
        self.assertEqual(c.exception.status,429)
    def test_revocation_uses_private_issuer_only(self):
        t=Fake();r=self.broker(t).handle('Bearer fixture-owner',REQ,True)
        self.assertTrue(r['revoked']);self.assertEqual([x[0] for x in t.calls],[PRIVATE])
    def test_failed_socket_proof_revokes_issued_session(self):
        t=Fake();t.websocket=lambda cookie:(_ for _ in ()).throw(Failure())
        with self.assertRaises(Failure):self.broker(t).handle('Bearer fixture-owner',REQ)
        self.assertTrue(t.revoked)
    def test_missing_memory_is_reported_without_skipping_voice_authentication(self):
        t=Fake();t.memory_missing=True
        r=self.broker(t).handle('Bearer fixture-owner',REQ)
        self.assertIs(r['memory_available'],False)
        self.assertIn(ORIGIN+'/session',[c[0] for c in t.calls])
    def test_noncanonical_request_shape_is_rejected(self):
        for change in ({'version':True},{'installation_id':REQ['installation_id'].upper()}):
            with self.assertRaises(Failure) as caught:self.broker().handle('Bearer fixture-owner',dict(REQ,**change))
            self.assertEqual(caught.exception.status,400)
    def test_private_issuer_expiry_uses_current_time_after_network_proofs(self):
        t=Fake();original=t.fetch;clock=[NOW]
        def fetch(url,method='GET',headers=None,body=None):
            result=original(url,method,headers,body)
            if url==PRIVATE and method=='POST':
                status,h,raw=result;data=json.loads(raw);clock[0]=NOW+5;data['expires_at']=NOW+905
                return status,h,json.dumps(data).encode()
            return result
        t.fetch=fetch;b=Broker('fixture-owner',cfg,t,lambda:clock[0])
        self.assertEqual(b.handle('Bearer fixture-owner',REQ)['expires_at'],NOW+800)
    def test_independent_session_proofs_do_not_serialize_network_waits(self):
        import threading
        barrier=threading.Barrier(3);t=Fake();original=t.fetch
        def fetch(url,method='GET',headers=None,body=None):
            if url in (ORIGIN+'/session',ORIGIN+'/memory'):barrier.wait(timeout=2)
            return original(url,method,headers,body)
        def websocket(cookie):
            barrier.wait(timeout=2)
            self.assertIn('jarvis=',cookie)
        t.fetch=fetch;t.websocket=websocket
        self.assertEqual(self.broker(t).handle('Bearer fixture-owner',REQ)['version'],1)
    def test_redirects_are_not_followed(self):
        self.assertIsNone(NoRedirect().redirect_request(None,None,302,'',{},'https://evil.example/'))
if __name__=='__main__':unittest.main()
