import json
import sqlite3
import tempfile
import unittest
from pathlib import Path
from werkzeug.datastructures import MultiDict
from orbit_call_history import read_history


class CallHistoryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name); self.db = self.root / 'history.db'; self.registry = self.root / 'allowed-callers.json'
        self.registry.write_text(json.dumps({'version': 1, 'callers': [{'number': '+201000000001', 'enabled': False}]}))
        with sqlite3.connect(self.db) as c:
            c.execute('CREATE TABLE diaa_call_history(id TEXT,number TEXT,seen_at REAL)')
            c.executemany('INSERT INTO diaa_call_history VALUES(?,?,?)', [(str(i), '+201000000001', 100 + i) for i in range(55)])
            c.execute('INSERT INTO diaa_call_history VALUES(?,?,?)', ('other', '+201000000002', 120))
        self.args = dict(number='+201000000001', start='100', end='155', offset='0')
    def fetch(self, args=None): return read_history(self.args if args is None else args, self.db, self.registry, now=200)
    def test_current_registry_not_retired_friends_and_disabled_caller_history(self):
        data, status = self.fetch(); self.assertEqual(status, 200); self.assertEqual(data['total'], 55)
        self.assertEqual(len(data['calls']), 50); self.assertEqual(data['calls'][0]['seen_at'], 154)
        self.assertEqual(data['coverage'], 'recorded_diaa_calls')
    def test_pagination_and_date_bounds(self):
        data, status = self.fetch(dict(self.args, offset='50')); self.assertEqual(status, 200); self.assertEqual(len(data['calls']), 5)
        self.assertEqual(self.fetch(dict(self.args, start='120', end='122'))[0]['total'], 2)
    def test_unlisted_and_invalid_or_duplicate_parameters(self):
        self.assertEqual(self.fetch(dict(self.args, number='+201000000002'))[1], 404)
        for args in [dict(self.args, number='01000000001'), dict(self.args, start='155'), dict(self.args, offset='-1'), dict(self.args, offset='100001')]:
            self.assertEqual(self.fetch(args)[1], 422)
        self.assertEqual(self.fetch(MultiDict(list(self.args.items()) + [('number', '+201000000002')]))[1], 422)
    def test_missing_database_and_registry_fail_closed(self):
        self.db.unlink(); self.assertEqual(self.fetch()[1], 503); self.assertFalse(self.db.exists())
        self.registry.write_text('[]'); self.assertEqual(self.fetch()[1], 503)
