from contextlib import closing
import json
from pathlib import Path
import sqlite3
import tempfile
import threading
import unittest
import uuid
from flask import Flask
from classera_report_settings import ReportSettings, Problem, register


class ReportSettingsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.path = Path(self.temp.name) / 'subscribers.sqlite3'
        with closing(sqlite3.connect(self.path)) as c, c:
            c.executescript('''CREATE TABLE subscribers(phone TEXT,name TEXT,class_name TEXT,ai_enabled INTEGER,status TEXT,joined_at TEXT,updated_at TEXT,PRIMARY KEY(phone,class_name));
              CREATE TABLE signup_sessions(phone TEXT PRIMARY KEY,step TEXT,name TEXT,class_name TEXT,updated_at TEXT);
              CREATE TABLE orbit_student_controls(phone TEXT PRIMARY KEY,activity_status TEXT,updated_at TEXT);''')
            for index, ai, status in [(1, 1, 'active'), (2, 0, 'active'), (3, 1, 'disabled'), (4, 1, 'active'), (5, 1, 'active'), (6, None, 'active'), (7, None, 'waiting_for_class'), (8, 1, 'active'), (9, 1, 'active')]:
                c.execute('INSERT INTO subscribers VALUES(?,?,?,?,?,?,?)', (str(201000000000 + index), 'Fixture', '12F', ai, status, 'joined', 'old'))
            c.execute("INSERT INTO subscribers VALUES('201000000001','Fixture','12E',1,'active','joined','old')")
            c.executemany('INSERT INTO orbit_student_controls VALUES(?,?,?)', [('201000000004', 'suspended', 'old'), ('201000000008', 'blocked', 'old'), ('201000000009', None, 'old')])
            c.execute("INSERT INTO signup_sessions VALUES('201000000005','name',NULL,'12F','old')")
        self.store = ReportSettings(self.path)
        self.store.migrate()
        app = Flask(__name__)
        register(app, 'owner-fixture', self.store)
        self.client = app.test_client()
        self.headers = {'Authorization': 'Bearer owner-fixture'}
        self.root = '/api/classera/report-settings/classera-1'

    def tearDown(self):
        self.temp.cleanup()

    def body(self, value=0):
        preview = self.store.preview('classera-1', {'ai_enabled': value})
        return {'request_id': str(uuid.uuid4()), 'expected_revision': preview['revision'],
                'ai_enabled': value, 'expected_affected_count': preview['affected_count']}

    def test_selected_class_atomic_change_preserves_paused_unknown_and_signup(self):
        snapshot = self.store.snapshot('classera-1')
        self.assertEqual(snapshot['counts'], {'eligible': 2, 'ai': 1, 'no_ai': 1, 'preserved': 7})
        result = self.store.mutate('classera-1', 'bulk-ai', self.body())
        self.assertEqual(result['affected_count'], 1)
        with closing(sqlite3.connect(self.path)) as c:
            rows = {(p, k): (ai, status, joined, updated) for p, k, ai, status, joined, updated in c.execute('SELECT phone,class_name,ai_enabled,status,joined_at,updated_at FROM subscribers')}
        self.assertEqual(rows[('201000000001', '12F')][:3], (0, 'active', 'joined'))
        self.assertEqual(rows[('201000000001', '12E')], (1, 'active', 'joined', 'old'))
        for index in [3, 4, 5, 8, 9]:
            self.assertEqual(rows[(str(201000000000 + index), '12F')][0], 1)
            self.assertEqual(rows[(str(201000000000 + index), '12F')][3], 'old')
        self.assertIsNone(rows[('201000000006', '12F')][0])

    def test_reverse_change_and_idempotency_never_repeat_mutation(self):
        body = self.body(1)
        result = self.store.mutate('classera-1', 'bulk-ai', body)
        self.assertEqual(result['affected_count'], 1)
        self.assertEqual(self.store.mutate('classera-1', 'bulk-ai', body), result)
        self.assertEqual(self.store.operation('classera-1', body['request_id']), result)
        body['ai_enabled'] = 0
        with self.assertRaises(Problem) as error:
            self.store.mutate('classera-1', 'bulk-ai', body)
        self.assertEqual(error.exception.status, 409)

    def test_stale_revision_and_count_fail_without_any_updates(self):
        for changed in ['revision', 'count']:
            body = self.body()
            if changed == 'revision': body['expected_revision'] = '0' * 64
            else: body['expected_affected_count'] += 1
            with self.assertRaises(Problem) as error:
                self.store.mutate('classera-1', 'bulk-ai', body)
            self.assertEqual(error.exception.status, 409)
        self.assertEqual(self.store.snapshot('classera-1')['counts']['ai'], 1)

    def test_signup_or_suspension_after_preview_invalidates_revision(self):
        body = self.body()
        with closing(sqlite3.connect(self.path)) as c, c:
            c.execute("INSERT INTO signup_sessions VALUES('201000000001','class',NULL,'12F','new')")
        with self.assertRaises(Problem) as error:
            self.store.mutate('classera-1', 'bulk-ai', body)
        self.assertEqual(error.exception.status, 409)

    def test_concurrent_requests_have_one_winner_for_same_preview(self):
        first, second = self.body(), self.body()
        output = []
        def run(body):
            try: output.append(self.store.mutate('classera-1', 'bulk-ai', body)['status'])
            except Problem as error: output.append(error.status)
        threads = [threading.Thread(target=run, args=(body,)) for body in [first, second]]
        for thread in threads: thread.start()
        for thread in threads: thread.join()
        self.assertCountEqual(output, ['completed', 409])

    def test_authentication_origin_methods_validation_and_no_store(self):
        self.assertEqual(self.client.get(self.root).status_code, 401)
        self.assertEqual(self.client.get(self.root, headers={'Authorization': 'Bearer wrong'}).status_code, 401)
        self.assertEqual(self.client.get(self.root, headers={**self.headers, 'Origin': 'https://example.test'}).status_code, 403)
        response = self.client.get(self.root, headers=self.headers)
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.headers['Cache-Control'], 'no-store')
        self.assertEqual(self.client.delete(self.root, headers=self.headers).status_code, 405)
        for value in [True, 2, None, '1']:
            self.assertEqual(self.client.post(self.root + '/bulk-ai/preview', headers=self.headers, json={'ai_enabled': value}).status_code, 422)
        self.assertEqual(self.client.get('/api/classera/report-settings/classera-3', headers=self.headers).status_code, 404)
        body = self.body()
        response = self.client.post(self.root + '/bulk-ai/operations', headers=self.headers, json=body)
        self.assertEqual(response.status_code, 200)
        self.assertEqual(self.client.get(self.root + '/operations/' + body['request_id'], headers=self.headers).json, response.json)

    def test_missing_database_is_not_created_and_failures_are_safe(self):
        missing = Path(self.temp.name) / 'absent.db'
        with self.assertRaises(sqlite3.Error): ReportSettings(missing).snapshot('classera-1')
        self.assertFalse(missing.exists())
        with closing(sqlite3.connect(self.path)) as c, c: c.execute('DROP TABLE subscribers')
        response = self.client.get(self.root, headers=self.headers)
        self.assertEqual(response.status_code, 503)
        self.assertEqual(response.json, {'error': 'report_settings_unavailable'})

    def test_explicit_cancellation_prevents_late_arriving_original_request(self):
        body = self.body()
        cancelled = self.store.cancel_unresolved('classera-1', body['request_id'])
        self.assertEqual(cancelled['status'], 'cancelled')
        self.assertEqual(self.store.cancel_unresolved('classera-1', body['request_id']), cancelled)
        with self.assertRaises(Problem) as error: self.store.mutate('classera-1', 'bulk-ai', body)
        self.assertEqual(error.exception.status, 409)
        self.assertEqual(self.store.snapshot('classera-1')['counts']['ai'], 1)

    def test_cancel_after_completion_reports_existing_result_without_reverting(self):
        body = self.body()
        completed = self.store.mutate('classera-1', 'bulk-ai', body)
        self.assertEqual(self.store.cancel_unresolved('classera-1', body['request_id']), completed)
        self.assertEqual(self.store.snapshot('classera-1')['counts']['ai'], 0)

    def test_sqlite_failure_rolls_back_the_entire_operation(self):
        body = self.body()
        with closing(sqlite3.connect(self.path)) as c, c:
            c.execute("CREATE TRIGGER reject_update BEFORE UPDATE ON subscribers BEGIN SELECT RAISE(ABORT,'fixture abort'); END")
        with self.assertRaises(sqlite3.Error): self.store.mutate('classera-1', 'bulk-ai', body)
        self.assertEqual(self.store.snapshot('classera-1')['counts']['ai'], 1)
        with self.assertRaises(Problem): self.store.operation('classera-1', body['request_id'])

    def test_notice_gate_and_single_logical_batch_do_not_send_or_requeue(self):
        body = {'request_id': str(uuid.uuid4()), 'expected_revision': self.store.snapshot('classera-1')['revision'], 'text': 'Fixture notice'}
        with self.assertRaises(Problem) as error: self.store.mutate('classera-1', 'next-notice', body)
        self.assertEqual(error.exception.code, 'notice_contract_unverified')
        self.store.notice_ready = lambda: True  # Fixture adapter; no provider code.
        result = self.store.mutate('classera-1', 'next-notice', body)
        self.assertEqual(result['settings']['queued_notice']['text'], 'Fixture notice')
        people = ['201000000001', '201000000002']
        self.assertIsNone(self.store.claim_notice('classera-1', 'manual', people, single=True))
        self.assertIsNone(self.store.claim_notice('classera-1', 'forced', people, forced=True))
        notice = self.store.claim_notice('classera-1', 'daily-batch', people)
        self.assertEqual(self.store.claim_notice('classera-1', 'daily-batch', people)['id'], notice['id'])
        self.assertIsNone(self.store.claim_notice('classera-1', 'next-day', people))
        self.assertEqual(self.store.reserve_notice_target(notice['id'], people[0]), 'Fixture notice')
        self.assertIsNone(self.store.reserve_notice_target(notice['id'], people[0]))
        self.assertIsNone(self.store.reserve_notice_target(notice['id'], '201000000099'))
        self.store.record_notice_result(notice['id'], people[0], 'accepted')
        self.assertEqual(self.store.reserve_notice_target(notice['id'], people[1]), 'Fixture notice')
        self.store.record_notice_result(notice['id'], people[1], 'unknown')
        self.assertEqual(self.store.snapshot('classera-1')['latest_notice']['state'], 'partial')
        self.assertIsNone(self.store.snapshot('classera-1')['queued_notice'])

    def test_clearing_queued_notice_never_removes_claimed_batch(self):
        self.store.notice_ready = lambda: True
        def save(text):
            return self.store.mutate('classera-1', 'next-notice', {'request_id': str(uuid.uuid4()), 'expected_revision': self.store.snapshot('classera-1')['revision'], 'text': text})
        save('Keep in batch')
        claimed = self.store.claim_notice('classera-1', 'one', ['201000000001'])
        save('Later queued notice')
        save('')
        self.assertIsNone(self.store.snapshot('classera-1')['queued_notice'])
        self.assertEqual(self.store.reserve_notice_target(claimed['id'], '201000000001'), 'Keep in batch')


if __name__ == '__main__': unittest.main()
