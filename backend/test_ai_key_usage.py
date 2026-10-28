import hashlib
import json
import sqlite3
import tempfile
import unittest
from datetime import datetime
from pathlib import Path
from flask import Flask
from ai_key_usage import CAIRO, Usage, configured_keys, register, Unavailable


class UsageTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.path = self.root / 'usage.db'
        self.now = lambda: datetime(2026, 10, 28, 0, 20, tzinfo=CAIRO)
        self.keys = lambda: (['aaa', 'bbb', 'ccc', 'ddd'], {'12F': ['aaa', 'bbb', 'ccc', 'ddd'], '12E': ['aaa', 'bbb', 'ccc', 'ddd']})
        self.usage = Usage(self.path, self.keys, self.now)

    def tearDown(self):
        self.temp.cleanup()

    def database(self):
        with sqlite3.connect(self.path) as c:
            c.execute('CREATE TABLE ai_requests(day TEXT,timestamp TEXT,class_name TEXT,key_id TEXT,status TEXT,http_status INTEGER)')
            c.executemany('INSERT INTO ai_requests VALUES(?,?,?,?,?,?)', [
                ('2026-10-28', '2026-10-28T00:01:00+03:00', '12F', 'aaa', 'http_error', 429),
                ('2026-10-28', '2026-10-28T00:02:00+03:00', '12F', 'bbb', 'success', 200),
                ('2026-10-27', '2026-10-27T22:00:00+03:00', '12E', 'aaa', 'success', 200),
                ('2026-10-21', '2026-10-21T22:00:00+03:00', '12F', 'aaa', 'error', None),
                ('2026-10-01', '2026-10-01T22:00:00+03:00', '12E', 'retired-sensitive-fingerprint', 'success', 200),
                ('2026-10-28', '2026-10-28T00:03:00+03:00', 'other', 'ccc', 'success', 200),
                ('2026-10-29', '2026-10-29T00:03:00+03:00', '12F', 'ccc', 'success', 200)])

    def test_missing_database_waits_without_creating_it(self):
        value = self.usage.snapshot()
        self.assertFalse(self.path.exists())
        self.assertEqual(value['state'], 'waiting')
        self.assertEqual(value['recommendation'], 'Waiting for usage data')
        self.assertEqual(value['configured_keys'], 4)
        self.assertEqual(len(value['keys']), 4)
        self.assertTrue(all(r['requests'] == 0 for r in value['keys']))

    def test_missing_table_is_waiting(self):
        sqlite3.connect(self.path).close()
        self.assertEqual(self.usage.snapshot()['state'], 'waiting')
        with sqlite3.connect(self.path) as c:
            self.assertFalse(c.execute("SELECT name FROM sqlite_master WHERE type='table'").fetchall())

    def test_counts_class_filters_zero_keys_and_seven_day_boundaries(self):
        self.database()
        value = self.usage.snapshot(7, '12F')
        self.assertEqual((value['requests_today'], value['rate_limits_today'], value['active_keys_today']), (2, 1, 2))
        self.assertEqual([r['requests'] for r in value['keys']], [1, 1, 0, 0])
        self.assertEqual(value['keys'][0]['failed'], 1)
        self.assertEqual(value['keys'][1]['successful'], 1)
        self.assertEqual({p['day'] for p in value['daily']}, {f'2026-10-{d}' for d in range(22, 29)})
        self.assertIn('Only 2 of 4', value['recommendation'])
        self.assertIn('after rate-limit errors', value['recommendation'])
        self.assertEqual(self.usage.snapshot(7, '12E')['requests_today'], 0)
        self.assertEqual(self.usage.snapshot(1)['keys'][0]['requests'], 1)
        self.assertEqual(self.usage.snapshot(30)['keys'][0]['requests'], 3)

    def test_read_only_bytes_and_schema_remain_identical(self):
        self.database()
        before = self.path.read_bytes()
        self.usage.snapshot(30)
        self.assertEqual(before, self.path.read_bytes())
        with self.usage._connect() as c:
            with self.assertRaises(sqlite3.OperationalError):
                c.execute('DELETE FROM ai_requests')

    def test_no_raw_ids_keys_models_errors_or_cross_class_rows_are_exposed(self):
        self.database()
        value = self.usage.snapshot(30)
        encoded = json.dumps(value)
        for secret in ['retired-sensitive-fingerprint', 'aaa', 'bbb', 'ccc', 'http_error']:
            self.assertNotIn(secret, encoded)
        self.assertEqual(value['unmapped_keys'], 1)
        self.assertEqual(self.usage.snapshot(30)['keys'][-1]['label'], 'Unmapped key 1')

    def test_key_loader_preserves_order_deduplicates_and_does_not_import_provider(self):
        (self.root / 'shared').mkdir()
        secret_a, secret_b = 'fixture-key-one', 'fixture-key-two'
        (self.root / 'shared/.env').write_text(f'GEMINI_API_KEYS="{secret_b},{secret_a},{secret_b}"\n')
        expected = [hashlib.sha256(k.encode()).hexdigest()[:12] for k in (secret_b, secret_a)]
        ordered, classes = configured_keys(self.root)
        self.assertEqual(ordered, expected)
        self.assertEqual(classes['12F'], expected)
        self.assertNotIn(secret_a, json.dumps((ordered, classes)))
        (self.root / 'shared/.env').write_text('GEMINI_API_KEYS=${UNKNOWN}\n')
        with self.assertRaises(Unavailable): configured_keys(self.root)

    def test_cairo_today_and_empty_period_do_not_imply_new_keys_needed(self):
        self.database()
        value = self.usage.snapshot(1, '12E')
        self.assertEqual(value['requests_today'], 0)
        self.assertEqual(value['state'], 'ready')
        self.assertIn('Only 0 of 4', value['recommendation'])
        self.assertNotIn('after rate-limit', value['recommendation'])

    def test_auth_filters_safe_errors_and_get_only(self):
        app = Flask(__name__)
        register(app, 'owner-fixture', self.usage)
        client = app.test_client()
        path = '/api/classera/ai-key-usage'
        headers = {'Authorization': 'Bearer owner-fixture'}
        self.assertEqual(client.get(path).status_code, 401)
        self.assertEqual(client.get(path, headers={'X-API-Key': 'owner-fixture'}).status_code, 401)
        self.assertEqual(client.post(path, headers=headers).status_code, 405)
        self.assertEqual(client.get(path, headers=headers).headers['Cache-Control'], 'no-store')
        for query in ['days=0', 'days=9000', 'class_name=12G', 'days=7&days=30', 'extra=x', "class_name=12F%27"]:
            self.assertEqual(client.get(path+'?'+query, headers=headers).status_code, 422)
        self.path.write_text('corrupt private data')
        response = client.get(path, headers=headers)
        self.assertEqual(response.status_code, 503)
        self.assertEqual(response.json, {'error': 'usage_unavailable'})


if __name__ == '__main__':
    unittest.main()
