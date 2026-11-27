import json
import sys
import types
import unittest
from classera_report_notices import NoticeTransport, NoticeDispatch, report_date_label
from install_report_notices import patch_sender
import test_report_settings as fixturelib


class Response:
    status_code = 200
    def __init__(self, value): self.value = value
    def json(self): return self.value


class FakeProvider:
    def __init__(self, window=None, approved=True):
        self.evidence = window or {'window_open': False, 'seconds_left': 0}
        self.approved = approved; self.calls = []; self.http = self
    def settings(self, name): return 'fixture-key', '123456789'
    def window(self, *args): self.calls.append('window'); return self.evidence
    def send(self, phone, name, text): self.calls.append(('plaintext', text)); return 'accepted', 'fixture'
    def get(self, url, **kwargs):
        self.calls.append(('GET', url, kwargs))
        if '/phone_numbers' in url: return Response({'data': [{'phone_number_id': '123456789', 'business_account_id': '987654321'}]})
        return Response({'data': [{'name': 'classera_wa_notice', 'language': 'en_US', 'status': 'APPROVED' if self.approved else 'PENDING', 'components': [{'type': 'HEADER', 'format': 'TEXT', 'text': 'Notice'}, {'type': 'BODY', 'text': '*Notice for {{1}} - {{2}}:*\n\n- {{3}}'}]}]})
    def post(self, url, **kwargs): self.calls.append(('POST', url, kwargs)); return Response({'messages': [{'id': 'fixture'}]})


class NoticeTransportTests(unittest.TestCase):
    def test_open_window_uses_one_freeform_without_template_calls(self):
        provider = FakeProvider({'window_open': True, 'seconds_left': 300})
        self.assertEqual(NoticeTransport(provider).send('201000000001', '12F', 'Fixture'), 'accepted')
        self.assertEqual(provider.calls, ['window', ('plaintext', '*Notice for 12F:*\n\n- Fixture')])

    def test_closed_window_never_uses_template(self):
        provider = FakeProvider()
        self.assertEqual(NoticeTransport(provider).send('201000000001', '12F', 'Fixture', report_date='1/11/2026'), 'skipped_window_closed')
        self.assertEqual(provider.calls, ['window'])


    def test_unknown_near_expiry_or_unapproved_never_sends_freeform(self):
        for window in [{'window_open': None, 'seconds_left': None}, {'window_open': True, 'seconds_left': 2}, {'window_open': True, 'seconds_left': 86401}, {'window_open': False, 'seconds_left': 0}]:
            provider = FakeProvider(window, approved=False)
            self.assertTrue(NoticeTransport(provider).send('201000000001', '12F', 'Fixture').startswith('skipped_window_'))
            self.assertFalse(any(isinstance(c, tuple) and c[0] in ['POST', 'plaintext'] for c in provider.calls))

    def test_suspension_during_window_lookup_prevents_send(self):
        provider = FakeProvider({'window_open': True, 'seconds_left': 300})
        self.assertEqual(NoticeTransport(provider).send('201000000001', '12F', 'Fixture', allowed=lambda: False), 'skipped_ineligible')
        self.assertEqual(provider.calls, ['window'])

    def test_timeout_never_falls_back_or_retries_mutation(self):
        provider = FakeProvider({'window_open': True, 'seconds_left': 300})
        def timeout(*args): provider.calls.append('one-send'); raise TimeoutError()
        provider.send = timeout
        self.assertEqual(NoticeTransport(provider).send('201000000001', '12F', 'Fixture'), 'unknown')
        self.assertEqual(provider.calls, ['window', 'one-send'])

    def test_unknown_window_never_uses_template_metadata(self):
        provider = FakeProvider({'window_open': None, 'seconds_left': None})
        self.assertEqual(NoticeTransport(provider).send('201000000001', '12F', 'Fixture'), 'skipped_window_unknown')
        self.assertEqual(provider.calls, ['window'])


    def test_unknown_report_date_never_uses_today_for_a_template(self):
        provider = FakeProvider()
        self.assertEqual(NoticeTransport(provider).send('201000000001', '12F', 'Fixture'), 'skipped_window_closed')
        self.assertFalse(any(isinstance(c, tuple) and c[0] == 'POST' for c in provider.calls))
        self.assertEqual(report_date_label('12F 1/11/26'), '1/11/2026')
        self.assertEqual(report_date_label('12E 29_02_2024'), '29/2/2024')
        self.assertIsNone(report_date_label('12F 29/2/26'))
        self.assertIsNone(report_date_label('12F 1/11'))

    def test_plaintext_keeps_selected_class_and_actual_report_date(self):
        provider = FakeProvider({'window_open': True, 'seconds_left': 300})
        self.assertEqual(NoticeTransport(provider).send('201000000001', '12E', 'Fixture', report_date='2/11/2026'), 'accepted')
        self.assertEqual(provider.calls[-1], ('plaintext', '*Notice for 12E - 2/11/2026:*\n\n- Fixture'))


class NoticeBatchTests(unittest.TestCase):
    def setUp(self):
        self.fixture = fixturelib.ReportSettingsTests(); self.fixture.setUp()
        self.settings = self.fixture.store; self.settings.notice_ready = lambda: True
        self.sent = []
        sent = self.sent
        class Transport:
            def send(self, phone, klass, text, allowed, report_date=None):
                if not allowed(): return 'skipped_ineligible'
                sent.append((phone, klass, text)); return 'accepted'
        self.dispatch = NoticeDispatch(self.settings, Transport(), ready=lambda: True)
    def tearDown(self):
        import classera_report_notices
        classera_report_notices._dispatch = None
        self.fixture.tearDown()
    def queue(self):
        import uuid
        self.settings.mutate('classera-1', 'next-notice', {'request_id': str(uuid.uuid4()), 'expected_revision': self.settings.snapshot('classera-1')['revision'], 'text': 'Next report only'})

    def test_webhook_hook_requires_exact_recipient_parent_class_and_recent_inbound(self):
        import sqlite3, time, classera_report_notices
        path = self.settings.path.with_name('delivery-fixture.db')
        with sqlite3.connect(path) as c:
            c.execute('CREATE TABLE deliveries(report TEXT,recipient TEXT,message_id TEXT,classera_id TEXT,status TEXT)')
            c.execute('INSERT INTO deliveries VALUES(?,?,?,?,?)', ('12F 1/11/26','201000000001','parent-1','classera-1','delivered'))
        self.queue(); batch = self.dispatch.prepare('12F', '12F 1/11/26', ['201000000001'])
        self.dispatch.after_report(batch, '201000000001', True)
        classera_report_notices._dispatch = self.dispatch
        message = {'from':'201000000001','id':'inbound-1','timestamp':str(int(time.time())-1),'context':{'id':'parent-1'}}
        for changed in [dict(message, context={'id':'wrong'}), dict(message, timestamp='1'), dict(message, **{'from':'201000000002'})]:
            classera_report_notices.after_ai_request(changed, '12F', delivery_path=path)
        classera_report_notices.after_ai_request(message, '12E', delivery_path=path)
        self.assertEqual(self.sent, [])
        classera_report_notices.after_ai_request(message, '12F', delivery_path=path)
        classera_report_notices.after_ai_request(message, '12F', delivery_path=path)
        self.assertEqual(len(self.sent), 1)

    def test_transport_uncertainty_or_process_restart_never_resends_reserved_notice(self):
        self.queue(); batch = self.dispatch.prepare('12F', '12F 1/11/26', ['201000000001'])
        self.dispatch.after_report(batch, '201000000001', True)
        class UnknownTransport:
            def send(inner, *args, **kwargs): self.sent.append('attempt'); return 'unknown'
        self.dispatch.transport = UnknownTransport()
        self.dispatch.after_ai('201000000001', '12F', '12F 1/11/26')
        NoticeDispatch(self.settings, UnknownTransport(), ready=lambda: True).after_ai('201000000001', '12F', '12F 1/11/26')
        self.assertEqual(self.sent, ['attempt'])

    def test_reports_defer_notice_and_only_matching_ai_request_sends_once(self):
        self.queue(); people = ['201000000001', '201000000002']
        batch = self.dispatch.prepare('12F', '12F 1/11/26', people)
        for phone in people: self.dispatch.after_report(batch, phone, True)
        self.assertEqual(self.sent, [])
        self.assertEqual(self.settings.snapshot('classera-1')['latest_notice']['outcomes'], {'awaiting_ai': 2})
        self.dispatch.after_ai(people[0], '12F', 'another-report')
        self.dispatch.after_ai(people[0], '12E', '12F 1/11/26')
        self.assertEqual(self.sent, [])
        self.dispatch.after_ai(people[0], '12F', '12F 1/11/26')
        self.dispatch.after_ai(people[0], '12F', '12F 1/11/26')
        self.assertEqual(len(self.sent), 1)
        self.dispatch.after_ai(people[1], '12F', '12F 1/11/26')
        self.assertEqual(self.settings.snapshot('classera-1')['latest_notice']['outcomes'], {'accepted': 1, 'skipped_ineligible': 1})


    def test_notice_queued_after_a_batch_started_waits_for_next_new_report(self):
        people = ['201000000001']
        self.assertIsNone(self.dispatch.prepare('12F', 'old-report', people))
        self.queue()
        self.assertIsNone(self.dispatch.prepare('12F', 'old-report', people))
        self.assertIsNotNone(self.dispatch.prepare('12F', 'next-report', people))

    def test_partial_old_report_and_manual_sends_do_not_consume_queued_notice(self):
        self.queue(); people = ['201000000001']
        self.assertIsNone(self.dispatch.prepare('12F', 'one-person', people, single=True))
        self.assertIsNone(self.dispatch.prepare('12F', 'forced', people, forced=True))
        self.assertIsNone(self.dispatch.prepare('12F', 'partially-started', people, already_started=True))
        self.assertIsNotNone(self.settings.snapshot('classera-1')['queued_notice'])

    def test_failed_report_and_suspended_student_skip_notice(self):
        self.queue(); people = ['201000000001', '201000000004']
        batch = self.dispatch.prepare('12F', 'next-report', people)
        self.dispatch.after_report(batch, people[0], False)
        self.dispatch.after_report(batch, people[1], True)
        self.dispatch.after_ai(people[1], '12F', 'next-report')
        self.assertEqual(self.sent, [])
        self.assertEqual(self.settings.snapshot('classera-1')['latest_notice']['outcomes'], {'skipped_report_failed': 1, 'skipped_ineligible': 1})


class NoticePatchTests(unittest.TestCase):
    SOURCE = '''def notify_all(report_title, ai_summary, pdf_path):
    single_recipient = ""
    force_resend = False
    recipients = ["201000000001"]
    pending = [to for to in recipients if get_status(report_title, to, CLASSERA_ID) is None]
    media_id = upload_media(pdf_path)
    if not media_id:
        return False
    filename = os.path.basename(pdf_path)
    for to in recipients:
        try:
            result = send_template(to, media_id, filename, ai_summary, pdf_path, class_name=CLASSERA_CLASS)
            accepted.append(result)
        except Exception:
            failures.append(to)
    return True
'''
    def test_patch_only_adds_hooks_and_never_sends_during_import(self):
        patched = patch_sender(self.SOURCE)
        calls = []
        module = types.ModuleType('classera_report_notices')
        module.prepare = lambda *a, **k: calls.append(('prepare', k)) or {'fixture': True}
        def after(*args, **kwargs):
            self.assertEqual(context['accepted'], [True])
            calls.append(('after', kwargs))
        module.after_report = after
        old = sys.modules.get(module.__name__); sys.modules[module.__name__] = module
        try:
            context = {'os': types.SimpleNamespace(path=types.SimpleNamespace(basename=lambda _: 'fixture.pdf')),
                'upload_media': lambda _: 'fixture-media', 'send_template': lambda *a, **k: True,
                'get_status': lambda *a: None, 'CLASSERA_CLASS': '12F', 'CLASSERA_ID': 'classera-1', 'accepted': [], 'failures': []}
            exec(patched, context)
            self.assertEqual(calls, [])
            self.assertTrue(context['notify_all']('fixture', 'fixture', 'no-real-pdf'))
            self.assertEqual([c[0] for c in calls], ['prepare', 'after'])
            self.assertEqual(context['accepted'], [True])
        finally:
            if old is None: del sys.modules[module.__name__]
            else: sys.modules[module.__name__] = old

    def test_changed_or_repeated_sender_patch_fails_closed(self):
        with self.assertRaises(RuntimeError): patch_sender('def notify_all(other): pass')
        with self.assertRaises(RuntimeError): patch_sender(patch_sender(self.SOURCE))


if __name__ == '__main__': unittest.main()
