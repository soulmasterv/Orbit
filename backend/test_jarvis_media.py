import base64
import io
import unittest
from unittest.mock import patch, Mock
from flask import Flask
from orbit_jarvis_native import register, MEDIA_LIMIT, media_forward

class NativeMediaTests(unittest.TestCase):
    def setUp(self):
        self.app=Flask(__name__)
        self.calls=[]
        def media(identifier, method, query, stream, length):
            self.calls.append((identifier, method, query, stream.read() if method=='PUT' else None))
            return ({'id':identifier,'kind':'document','name':query.get('name'),'size':length},200) if method=='PUT' else (io.BytesIO(b'fixture document'),200)
        register(self.app,'fixture-owner',media_transport=media)
        self.client=self.app.test_client()
        self.path='/api/jarvis/whatsapp/media/11111111-1111-4111-8111-111111111111'
        self.auth={'Authorization':'Bearer fixture-owner','X-Orbit-File-Name':base64.b64encode('Fixture.pdf'.encode()).decode()}
    def test_media_requires_owner_auth_and_rejects_browser_origin(self):
        self.assertEqual(self.client.get(self.path).status_code,401)
        self.assertEqual(self.client.put(self.path+'?kind=document&mime=application/pdf',headers={**self.auth,'Origin':'https://example.com'},data=b'fixture').status_code,401)
        self.assertEqual(self.calls,[])
    def test_upload_metadata_is_validated_and_filename_is_not_in_url(self):
        response=self.client.put(self.path+'?kind=document&mime=application/pdf',headers=self.auth,data=b'fixture')
        self.assertEqual(response.status_code,200)
        self.assertEqual(self.calls[0][2]['name'],'Fixture.pdf')
        self.assertEqual(self.calls[0][3],b'fixture')
        self.assertEqual(response.headers['Cache-Control'],'no-store')
    def test_invalid_identifier_kind_filename_and_mime_do_not_reach_adapter(self):
        self.assertEqual(self.client.get('/api/jarvis/whatsapp/media/not-a-uuid',headers=self.auth).status_code,404)
        for query in ['?kind=shell&mime=application/pdf','?kind=document&mime=bad']:
            self.assertEqual(self.client.put(self.path+query,headers=self.auth,data=b'fixture').status_code,400)
        self.assertEqual(self.client.put(self.path+'?kind=document&mime=application/pdf',headers={'Authorization':'Bearer fixture-owner','X-Orbit-File-Name':'invalid'},data=b'fixture').status_code,400)
        self.assertEqual(self.calls,[])
    def test_oversized_and_empty_uploads_rejected_before_forwarding(self):
        self.assertEqual(self.client.put(self.path+'?kind=document&mime=application/pdf',headers=self.auth,data=b'').status_code,413)
        self.assertEqual(self.client.put(self.path+'?kind=document&mime=application/pdf',headers=self.auth,data=b'x'*(MEDIA_LIMIT+1)).status_code,413)
        self.assertEqual(self.calls,[])
    def test_downloads_are_attachments_and_not_executable_html(self):
        response=self.client.get(self.path,headers=self.auth)
        self.assertEqual(response.status_code,200)
        self.assertEqual(response.data,b'fixture document')
        self.assertEqual(response.headers['Content-Type'],'application/octet-stream')
        self.assertEqual(response.headers['X-Content-Type-Options'],'nosniff')
        self.assertIn('attachment',response.headers['Content-Disposition'])
        response.close()
    def test_binary_proxy_uses_fixed_host_and_streams_original_bytes(self):
        connection=Mock()
        response=connection.getresponse.return_value
        response.status=200
        response.read.return_value=b'{"id":"fixture"}'
        key=Mock();key.read_text.return_value='fixture-key'
        body=b'fixture'*30000
        with patch('orbit_jarvis_native.KEY',key),patch('orbit_jarvis_native.http.client.HTTPConnection',return_value=connection) as factory:
            value,status=media_forward('11111111-1111-4111-8111-111111111111','PUT',{'kind':'document','name':'Fixture.pdf','mime':'application/pdf'},io.BytesIO(body),len(body))
        factory.assert_called_once_with('127.0.0.1',18085,timeout=60)
        self.assertEqual(b''.join(call.args[0] for call in connection.send.call_args_list),body)
        connection.putheader.assert_any_call('Authorization','Bearer fixture-key')
        self.assertEqual(status,200)
        self.assertEqual(value['id'],'fixture')
        connection.close.assert_called_once()
    def test_binary_proxy_closes_connection_after_download(self):
        connection=Mock()
        response=connection.getresponse.return_value
        response.status=200
        response.read.side_effect=[b'fixture bytes',b'']
        key=Mock();key.read_text.return_value='fixture-key'
        with patch('orbit_jarvis_native.KEY',key),patch('orbit_jarvis_native.http.client.HTTPConnection',return_value=connection):
            file,status=media_forward('11111111-1111-4111-8111-111111111111','GET',{})
        self.assertEqual(file.read(),b'fixture bytes')
        file.close()
        self.assertEqual(status,200)
        connection.close.assert_called_once()

if __name__=='__main__':unittest.main()
