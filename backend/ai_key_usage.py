"""Read-only Classera Gemini accounting. No provider imports, writes or calls."""
import hashlib
import hmac
import re
import sqlite3
import time
from datetime import datetime, timedelta
from pathlib import Path
from zoneinfo import ZoneInfo
from flask import jsonify, request

CAIRO = ZoneInfo('Africa/Cairo')
ROOT = Path('/home/local/classera')
DB = ROOT / 'shared/ai_usage.db'


class Unavailable(Exception):
    pass


def configured_keys(root=ROOT):
    """Shared pool first, then explicit per-class overrides, preserving order.

    Return only recorder-compatible hashes. Secret values never leave this function.
    Read .env as data, never execute or import Classera's report/provider modules.
    """
    def pool(path):
        if not path.exists():
            return None
        values = {}
        for line in path.read_text().splitlines():
            line = line.strip()
            if line.startswith('export '):
                line = line[7:].lstrip()
            key, sep, value = line.partition('=')
            if sep and key.strip() == 'GEMINI_API_KEYS':
                value = value.strip()
                if value[:1] in ('"', "'"):
                    if len(value) < 2 or value[-1] != value[0]:
                        raise Unavailable()
                    value = value[1:-1]
                else:
                    value = value.split(' #', 1)[0].rstrip()
                # Do not guess shell interpolation/multiline semantics.
                if '$' in value or '\\' in value:
                    raise Unavailable()
                values[key.strip()] = value
        if 'GEMINI_API_KEYS' not in values:
            return None
        return list(dict.fromkeys(hashlib.sha256(k.strip().encode()).hexdigest()[:12]
                                 for k in values['GEMINI_API_KEYS'].split(',') if k.strip()))

    root = Path(root)
    shared = pool(root / 'shared/.env')
    by_class = {c: pool(root / folder / '.env') for c, folder in [('12F', 'classera-1'), ('12E', 'classera-2')]}
    if shared is None or not shared:
        raise Unavailable()
    by_class = {c: shared if keys is None else keys for c, keys in by_class.items()}
    ordered = list(dict.fromkeys(shared + by_class['12F'] + by_class['12E']))
    return ordered, by_class


class Usage:
    def __init__(self, path=DB, keys=configured_keys, now=lambda: datetime.now(CAIRO)):
        self.path, self.keys, self.now = Path(path), keys, now

    def snapshot(self, days=7, class_name='All'):
        if days not in (1, 7, 30) or class_name not in ('All', '12F', '12E'):
            raise ValueError()
        ordered, by_class = self.keys()
        selected = set(ordered if class_name == 'All' else by_class[class_name])
        now = self.now().astimezone(CAIRO)
        today = now.date()
        start = (today - timedelta(days=days - 1)).isoformat()
        chart_days = 30 if days == 30 else 7
        chart_start = (today - timedelta(days=chart_days - 1)).isoformat()
        labels = {key: ('key-' + str(i), 'Key ' + str(i)) for i, key in enumerate(ordered, 1)}
        rows, daily, lasts, after_limit = [], [], [], False
        waiting = not self.path.exists()
        if not waiting:
            # mode=ro never creates an empty DB. query_only additionally rejects writes.
            with self._connect() as c:
                waiting = not c.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='ai_requests'").fetchone()
                if not waiting:
                    columns = {r[1] for r in c.execute('PRAGMA table_info(ai_requests)')}
                    if not {'day', 'timestamp', 'class_name', 'key_id', 'status', 'http_status'}.issubset(columns):
                        raise Unavailable()
                    classes = ('12F', '12E') if class_name == 'All' else (class_name,)
                    clause = 'class_name IN (' + ','.join('?' for _ in classes) + ')'
                    # Exclude unrelated classes/future days. Raw keys, hashes, errors and models are never returned.
                    daily = c.execute('SELECT day,key_id,COUNT(*) FROM ai_requests WHERE ' + clause +
                        ' AND day>=? AND day<=? GROUP BY day,key_id', (*classes, chart_start, today.isoformat())).fetchall()
                    rows = c.execute("SELECT day,key_id,COUNT(*),SUM(CASE WHEN status='success' THEN 1 ELSE 0 END),"
                        "SUM(CASE WHEN http_status=429 THEN 1 ELSE 0 END) FROM ai_requests WHERE " + clause +
                        ' AND day>=? AND day<=? GROUP BY day,key_id', (*classes, min(start, today.isoformat()), today.isoformat())).fetchall()
                    lasts = c.execute('SELECT key_id,MAX(timestamp) FROM ai_requests WHERE ' + clause +
                        ' AND day<=? GROUP BY key_id', (*classes, today.isoformat())).fetchall()
                    # Evidence of ordering only, not a claim that adding keys will fix quota.
                    after_limit = bool(c.execute('SELECT 1 FROM ai_requests a WHERE ' +
                        clause.replace('class_name', 'a.class_name') +
                        ' AND a.day>=? AND a.day<=? AND a.http_status=429 AND EXISTS('
                        'SELECT 1 FROM ai_requests b WHERE b.class_name=a.class_name AND b.day=a.day '
                        'AND b.timestamp>a.timestamp AND b.key_id!=a.key_id) LIMIT 1',
                        (*classes, start, today.isoformat())).fetchone())

        # Unknown/retired fingerprints stay distinct, but are never transmitted.
        unknown = sorted(({r[1] for r in rows} | {r[1] for r in daily} | {r[0] for r in lasts}) - set(labels))
        for i, key in enumerate(unknown, 1):
            labels[key] = ('unmapped-' + str(i), 'Unmapped key ' + str(i))
        observed = {r[0] for r in lasts} | {r[1] for r in daily}
        visible = [k for k in labels if k in selected or k in observed]
        table = []
        last_used = {key: safe_time(value) for key, value in lasts}
        for key in visible:
            counts = [r for r in rows if r[1] == key and r[0] >= start]
            total, success, limited = (sum(r[i] for r in counts) for i in (2, 3, 4))
            identifier, label = labels[key]
            table.append(dict(id=identifier, label=label, configured=key in selected, requests=total,
                successful=success, failed=total-success, rate_limits=limited, last_used=last_used.get(key)))
        today_rows = [r for r in rows if r[0] == today.isoformat()]
        used = sum(r['requests'] > 0 for r in table if r['configured'])
        period = 'today' if days == 1 else 'in the last ' + str(days) + ' days'
        recommendation = ('Waiting for usage data' if waiting or not lasts else
            f'Only {used} of {len(selected)} configured keys used {period}.' if used < len(selected) else
            f'All {len(selected)} configured keys used {period}.')
        if after_limit:
            recommendation += ' Additional keys were used after rate-limit errors; this alone does not prove more keys are needed.'
        chart_counts = {(day, key): count for day, key, count in daily}
        chart = [dict(day=(today-timedelta(days=offset)).isoformat(), key_id=labels[key][0], label=labels[key][1],
            requests=chart_counts.get(((today-timedelta(days=offset)).isoformat(), key), 0))
            for offset in reversed(range(chart_days)) for key in visible]
        return dict(version=1, state='waiting' if waiting or not lasts else 'ready', timezone='Africa/Cairo',
            days=days, class_name=class_name, updated_at=int(now.timestamp()), configured_keys=len(selected),
            active_keys_today=len({r[1] for r in today_rows if r[1] in selected}),
            requests_today=sum(r[2] for r in today_rows), rate_limits_today=sum(r[4] for r in today_rows),
            chart_days=chart_days, daily=chart, keys=table, recommendation=recommendation,
            unmapped_keys=len(unknown))

    def _connect(self):
        from contextlib import contextmanager
        @contextmanager
        def connection():
            c = sqlite3.connect(self.path.resolve().as_uri()+'?mode=ro', uri=True, timeout=1)
            try:
                c.execute('PRAGMA query_only=ON')
                deadline = time.monotonic()+2
                c.set_progress_handler(lambda: int(time.monotonic() > deadline), 2000)
                c.execute('BEGIN')
                yield c
            finally:
                c.close()
        return connection()


def safe_time(value):
    try:
        date = datetime.fromisoformat(value)
        if date.tzinfo is None:
            date = date.replace(tzinfo=CAIRO)
        return date.isoformat()
    except (ValueError, TypeError):
        return None


def register(app, owner_token, usage=None):
    usage = usage or Usage()
    def get_usage():
        supplied = request.headers.get('Authorization', '')
        if not owner_token or not hmac.compare_digest(supplied.encode(), ('Bearer '+owner_token).encode()):
            result, status = dict(error='unauthorized'), 401
        else:
            try:
                if set(request.args)-{'days', 'class_name'} or any(len(request.args.getlist(k)) != 1 for k in request.args):
                    raise ValueError()
                result, status = usage.snapshot(int(request.args.get('days', '7')), request.args.get('class_name', 'All')), 200
            except (ValueError, TypeError):
                result, status = dict(error='invalid_filter'), 422
            except (sqlite3.Error, OSError, Unavailable):
                result, status = dict(error='usage_unavailable'), 503
        response = jsonify(result)
        response.status_code = status
        response.headers['Cache-Control'] = 'no-store'
        return response
    app.add_url_rule('/api/classera/ai-key-usage', 'orbit_ai_key_usage', get_usage, methods=['GET'])
