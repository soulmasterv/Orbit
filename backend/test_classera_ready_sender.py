import json
from pathlib import Path
import tempfile
import unittest
from classera_ready_sender import ReadySender, template_valid, BODY, PAYLOAD


class ReadySenderTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.root = Path(self.temp.name)
        (self.root / 'shared').mkdir()
        (self.root / 'classera-1').mkdir()
        (self.root / 'shared/kapso.env').write_text('KAPSO_API_KEY=provider-fixture\nKAPSO_PHONE_NUMBER_ID=123456789\nKAPSO_API_BASE=https://api.kapso.ai/meta/whatsapp\n')
        self.env = self.root / 'classera-1/.env'
        self.env.write_text('CLASSERA_CLASS=12F\nWHATSAPP_PROVIDER=kapso\nCLASSERA_CLASS_READY_TEMPLATE_ENABLED=1\nCLASSERA_CLASS_READY_TEMPLATE_NAME=classera_class_ready\nCLASSERA_TEMPLATE_LANGUAGE=en_US\n')
        self.template = {'name': 'classera_class_ready', 'language': 'en_US', 'status': 'APPROVED', 'components': [
            {'type': 'HEADER', 'format': 'TEXT', 'text': 'Class available'},
            {'type': 'BODY', 'text': BODY}, {'type': 'BUTTONS', 'buttons': [{'type': 'QUICK_REPLY', 'text': 'Opt-in'}]}]}
        self.proof = {'version': 1, 'verified_at': 1700000000, 'phone_id': '123456789',
            'callback_payload': PAYLOAD, 'callback_verified': True, 'template': self.template}
        self.receipt = self.root / 'shared/class_ready_contract.json'
        self.write_proof()
        self.calls = []
        self.adapter = ReadySender(self.root, post=self.post, now=lambda: 1700000010)

    def tearDown(self): self.temp.cleanup()
    def write_proof(self): self.receipt.write_text(json.dumps(self.proof))
    def post(self, url, **kwargs):
        self.calls.append((url, kwargs))
        class Response:
            status_code = 200
            def json(self): return {'messages': [{'id': 'wamid.fixture'}]}
        return Response()

    def test_exact_approved_template_language_body_header_and_button(self):
        self.assertTrue(template_valid(self.template))
        for key, value in [('status', 'PENDING'), ('language', 'en_us'), ('name', 'classera_class_ready_v5')]:
            changed = {**self.template, key: value}
            self.assertFalse(template_valid(changed))
        self.template['components'][0]['text'] = 'Dynamic {{1}}'
        self.assertFalse(template_valid(self.template))

    def test_construction_catalog_and_disabled_flags_never_send(self):
        original = lambda: [{'id': '12F', 'name': '12F', 'supported': True}]
        self.assertTrue(self.adapter.catalog(original)()[0]['template_verified'])
        self.assertEqual(self.calls, [])
        self.env.write_text(self.env.read_text().replace('ENABLED=1', 'ENABLED=0'))
        self.assertFalse(self.adapter.catalog(original)()[0]['template_verified'])
        self.assertEqual(self.adapter.send('12F', '201000000001'), {'status': 'failed'})
        self.assertEqual(self.calls, [])

    def test_sender_payload_keeps_provider_key_out_of_body_and_does_not_subscribe(self):
        self.assertEqual(self.adapter.send('12F', '201000000001'), {'status': 'accepted', 'message_id': 'wamid.fixture'})
        self.assertEqual(len(self.calls), 1)
        url, request = self.calls[0]
        self.assertEqual(url, 'https://api.kapso.ai/meta/whatsapp/v24.0/123456789/messages')
        self.assertFalse(request['allow_redirects']); self.assertEqual(request['timeout'], 12)
        self.assertEqual(request['headers']['X-API-Key'], 'provider-fixture')
        self.assertNotIn('provider-fixture', json.dumps(request['json']))
        template = request['json']['template']
        self.assertEqual(template['name'], 'classera_class_ready')
        self.assertEqual(template['language']['code'], 'en_US')
        self.assertEqual(template['components'][0]['parameters'], [{'type': 'text', 'text': '12F'}])
        self.assertEqual(template['components'][1]['parameters'], [{'type': 'payload', 'payload': 'selfservice_optin'}])

    def test_missing_wrong_or_expired_receipt_fails_closed(self):
        for field, value in [('callback_verified', False), ('phone_id', '00000'), ('expires_at', 1700000005)]:
            original = dict(self.proof); self.proof[field] = value; self.write_proof()
            self.assertIsNone(self.adapter.proof()); self.assertFalse(self.adapter.enabled('12F'))
            self.proof = original
        self.receipt.unlink()
        self.assertIsNone(self.adapter.proof()); self.assertEqual(self.calls, [])

    def test_other_class_unknown_phone_and_untrusted_provider_base_never_send(self):
        self.assertEqual(self.adapter.send('12D', '201000000001'), {'status': 'failed'})
        self.assertEqual(self.adapter.send('12F', '../recipient'), {'status': 'failed'})
        path = self.root / 'shared/kapso.env'
        path.write_text(path.read_text().replace('https://api.kapso.ai', 'https://evil.test'))
        self.assertIsNone(self.adapter.proof()); self.assertEqual(self.calls, [])

    def test_timeout_and_unconfirmed_success_have_no_automatic_retry(self):
        count = []
        def timeout(*args, **kwargs): count.append(1); raise TimeoutError()
        self.adapter.post = timeout
        self.assertEqual(self.adapter.send('12F', '201000000001'), {'status': 'unknown'})
        self.assertEqual(len(count), 1)
        class EmptyResponse:
            status_code = 200
            def json(self): return {}
        self.adapter.post = lambda *args, **kwargs: EmptyResponse()
        self.assertEqual(self.adapter.send('12F', '201000000001'), {'status': 'unknown'})


if __name__ == '__main__': unittest.main()
