"""Read-only history for the current Allowed callers registry.

The existing authenticated phone-pilot route delegates here. No call is placed,
no table is created, and a missing history database never becomes an empty one.
"""
import json
import math
import re
import sqlite3
import time
from contextlib import closing
from pathlib import Path


def read_history(args, broker_db, callers_file, now=None):
    now = int(time.time()) if now is None else int(now)
    try:
        if set(args) != {'number', 'start', 'end', 'offset'}:
            raise ValueError()
        if hasattr(args, 'getlist') and any(len(args.getlist(k)) != 1 for k in args):
            raise ValueError()
        number = args['number']
        start, end, offset = (int(args[k]) for k in ('start', 'end', 'offset'))
        if not re.fullmatch(r'\+[1-9][0-9]{7,14}', number) or not (0 <= start < end <= now + 172800) or not (0 <= offset <= 100000):
            raise ValueError()
    except (ValueError, TypeError, KeyError):
        return {'error': 'invalid_range'}, 422
    try:
        registry = json.loads(Path(callers_file).read_text())
        if registry.get('version') != 1 or not isinstance(registry.get('callers'), list):
            raise ValueError()
        if not any(isinstance(row, dict) and row.get('number') == number for row in registry['callers']):
            return {'error': 'caller_not_found'}, 404
        with closing(sqlite3.connect(Path(broker_db).resolve().as_uri() + '?mode=ro', uri=True)) as connection:
            connection.execute('BEGIN')
            values = (number, start, end)
            total = connection.execute('SELECT COUNT(*) FROM diaa_call_history WHERE number=? AND seen_at>=? AND seen_at<?', values).fetchone()[0]
            rows = list(connection.execute('SELECT id,seen_at FROM diaa_call_history WHERE number=? AND seen_at>=? AND seen_at<? ORDER BY seen_at DESC,id DESC LIMIT 50 OFFSET ?', (*values, offset)))
            if any(not math.isfinite(float(row[1])) for row in rows):
                raise ValueError()
            return {'total': total, 'calls': [{'id': str(row[0]), 'seen_at': row[1]} for row in rows], 'coverage': 'recorded_diaa_calls'}, 200
    except (OSError, ValueError, TypeError, AttributeError, sqlite3.Error):
        return {'error': 'call_history_unavailable'}, 503
