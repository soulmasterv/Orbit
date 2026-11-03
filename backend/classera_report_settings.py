"""Owner-only report administration. No provider imports or network calls.

Bulk preferences share the existing subscriber database. Notices remain unavailable
unless a verified producer/template adapter explicitly advertises compatibility.
"""
from contextlib import contextmanager
from datetime import date, datetime, timezone
import hashlib
import hmac
import json
from pathlib import Path
import re
import sqlite3
import uuid

CLASSES = {'classera-1': '12F', 'classera-2': '12E'}
DB = '/home/local/classera/shared/subscribers.sqlite3'


class Problem(Exception):
    def __init__(self, code, status=422):
        self.code, self.status = code, status


def identifier(value):
    try:
        if not isinstance(value, str) or str(uuid.UUID(value)) != value:
            raise ValueError()
    except (ValueError, AttributeError):
        raise Problem('invalid_request')
    return value


def revision_value(value):
    if not isinstance(value, str) or not re.fullmatch(r'[a-f0-9]{64}', value):
        raise Problem('invalid_request')


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, ensure_ascii=False,
                                    separators=(',', ':')).encode()).hexdigest()


class ReportSettings:
    def __init__(self, path=DB, notice_ready=lambda: False):
        self.path, self.notice_ready = Path(path), notice_ready

    @contextmanager
    def connect(self, readonly=False):
        # Missing DB never creates a disconnected second subscriber database.
        connection = sqlite3.connect(self.path.resolve().as_uri() +
            ('?mode=ro' if readonly else '?mode=rw'), uri=True, timeout=5)
        connection.row_factory = sqlite3.Row
        connection.execute('PRAGMA busy_timeout=5000')
        try:
            with connection:
                yield connection
        finally:
            connection.close()

    def migrate(self):
        # Explicit startup only. Existing subscriber/control/session rows untouched.
        with self.connect() as c:
            c.executescript('''
            CREATE TABLE IF NOT EXISTS orbit_report_admin_operations(
              request_id TEXT PRIMARY KEY,class_id TEXT NOT NULL,kind TEXT NOT NULL,
              body_hash TEXT NOT NULL,result_json TEXT NOT NULL,created_at TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS orbit_report_notices(
              id TEXT PRIMARY KEY,class_id TEXT NOT NULL,text TEXT NOT NULL,
              state TEXT NOT NULL,batch_id TEXT,created_at TEXT NOT NULL);
            CREATE UNIQUE INDEX IF NOT EXISTS orbit_one_queued_notice
              ON orbit_report_notices(class_id) WHERE state='queued';
            CREATE TABLE IF NOT EXISTS orbit_report_notice_targets(
              notice_id TEXT NOT NULL,phone TEXT NOT NULL,outcome TEXT NOT NULL,
              PRIMARY KEY(notice_id,phone));
            CREATE TABLE IF NOT EXISTS orbit_notice_batches(
              class_id TEXT NOT NULL,batch_id TEXT NOT NULL,notice_id TEXT,
              PRIMARY KEY(class_id,batch_id));
            ''')

            c.execute('BEGIN IMMEDIATE')
            if 'scheduled_report_date' not in {row['name'] for row in c.execute('PRAGMA table_info(orbit_report_notices)')}:
                c.execute('ALTER TABLE orbit_report_notices ADD COLUMN scheduled_report_date TEXT')

    @staticmethod
    def class_name(class_id):
        if class_id not in CLASSES:
            raise Problem('class_not_found', 404)
        return CLASSES[class_id]

    def _snapshot(self, c, class_id):
        name = self.class_name(class_id)
        rows = [dict(r) for r in c.execute('''
          SELECT s.phone,s.class_name,s.ai_enabled,s.status,s.updated_at,
            CASE WHEN a.phone IS NULL THEN 'allowed' ELSE a.activity_status END AS activity_status,
            a.updated_at AS activity_updated_at,
            EXISTS(SELECT 1 FROM signup_sessions p WHERE p.phone=s.phone) AS signup
          FROM subscribers s LEFT JOIN orbit_student_controls a ON a.phone=s.phone
          WHERE s.class_name=? ORDER BY s.phone''', (name,))]
        latest = c.execute('SELECT id,text,state,batch_id,created_at,scheduled_report_date FROM orbit_report_notices '
                           'WHERE class_id=? ORDER BY created_at DESC,rowid DESC LIMIT 1', (class_id,)).fetchone()
        latest = dict(latest) if latest else None
        if latest:
            latest['outcomes'] = {r['outcome']: r['n'] for r in c.execute('SELECT outcome,COUNT(*) n FROM orbit_report_notice_targets WHERE notice_id=? GROUP BY outcome', (latest['id'],))}
        eligible = [r for r in rows if self._eligible(r)]
        queued = c.execute("SELECT id,text,state,batch_id,created_at,scheduled_report_date FROM orbit_report_notices WHERE class_id=? AND state='queued'", (class_id,)).fetchone()
        notice_available = bool(self.notice_ready())
        return {'version': 1, 'class_id': class_id, 'class_name': name,
            'revision': digest([rows, dict(queued) if queued else None, latest]),
            'capabilities': {'bulk_ai': True, 'next_notice': notice_available},
            'notice_unavailable_reason': None if notice_available else 'producer_integration_unverified',
            'queued_notice': dict(queued) if queued else None, 'latest_notice': latest,
            'counts': {'eligible': len(eligible), 'ai': sum(r['ai_enabled'] == 1 for r in eligible),
                'no_ai': sum(r['ai_enabled'] == 0 for r in eligible),
                'preserved': len(rows) - len(eligible)}}

    @staticmethod
    def _eligible(row):
        return (row['status'] == 'active' and row['activity_status'] == 'allowed'
                and not row['signup'] and row['ai_enabled'] in (0, 1))

    def snapshot(self, class_id):
        with self.connect(True) as c:
            c.execute('BEGIN')
            return self._snapshot(c, class_id)

    def history(self):
        with self.connect(True) as c:
            c.execute('BEGIN')
            operations = [dict(row) for row in c.execute("""
                SELECT request_id, class_id, kind, created_at,
                       json_extract(result_json, '$.affected_count') AS affected_count
                FROM orbit_report_admin_operations
                WHERE kind IN ('bulk-ai', 'next-notice')
                ORDER BY created_at DESC, rowid DESC LIMIT 100
            """)]
            notices = [dict(row) for row in c.execute("""
                SELECT id, class_id, text, state, created_at, scheduled_report_date
                FROM orbit_report_notices
                ORDER BY created_at DESC, rowid DESC LIMIT 100
            """)]
            for notice in notices:
                notice['outcomes'] = dict(c.execute("""
                    SELECT outcome, COUNT(*) FROM orbit_report_notice_targets
                    WHERE notice_id=? GROUP BY outcome
                """, (notice['id'],)).fetchall())
            return {'version': 1, 'operations': operations, 'notices': notices}

    def preview(self, class_id, body):
        self._ai_body(body)
        value = self.snapshot(class_id)
        value['ai_enabled'] = body['ai_enabled']
        value['affected_count'] = value['counts']['no_ai' if body['ai_enabled'] else 'ai']
        return value

    @staticmethod
    def _ai_body(body):
        if not isinstance(body, dict) or set(body) != {'ai_enabled'} or type(body['ai_enabled']) is not int or body['ai_enabled'] not in (0, 1):
            raise Problem('invalid_request')

    def operation(self, class_id, request_id):
        self.class_name(class_id); identifier(request_id)
        with self.connect(True) as c:
            row = c.execute('SELECT result_json FROM orbit_report_admin_operations WHERE request_id=? AND class_id=?', (request_id, class_id)).fetchone()
            if row is None:
                raise Problem('operation_not_found', 404)
            return json.loads(row['result_json'])

    def cancel_unresolved(self, class_id, request_id):
        """A tombstone prevents a delayed original request applying after recovery."""
        self.class_name(class_id); identifier(request_id)
        with self.connect() as c:
            c.execute('BEGIN IMMEDIATE')
            prior = c.execute('SELECT class_id,result_json FROM orbit_report_admin_operations WHERE request_id=?', (request_id,)).fetchone()
            if prior:
                if prior['class_id'] != class_id:
                    raise Problem('request_id_conflict', 409)
                return json.loads(prior['result_json'])
            result = {'version': 1, 'request_id': request_id, 'class_id': class_id,
                'kind': 'cancelled', 'status': 'cancelled', 'affected_count': 0,
                'settings': self._snapshot(c, class_id)}
            c.execute('INSERT INTO orbit_report_admin_operations VALUES(?,?,?,?,?,?)',
                (request_id, class_id, 'cancelled', 'cancelled', json.dumps(result), datetime.now(timezone.utc).isoformat()))
            return result

    def mutate(self, class_id, kind, body):
        name = self.class_name(class_id)
        expected = {'request_id', 'expected_revision', 'ai_enabled', 'expected_affected_count'} if kind == 'bulk-ai' else {'request_id', 'expected_revision', 'text'}
        if kind == 'next-notice' and isinstance(body, dict) and 'scheduled_report_date' in body:
            expected.add('scheduled_report_date')
        if not isinstance(body, dict) or set(body) != expected:
            raise Problem('invalid_request')
        request_id = identifier(body['request_id']); revision_value(body['expected_revision'])
        if kind == 'bulk-ai':
            self._ai_body({'ai_enabled': body['ai_enabled']})
            if type(body['expected_affected_count']) is not int or not 0 <= body['expected_affected_count'] <= 100000:
                raise Problem('invalid_request')
        elif kind == 'next-notice':
            scheduled = body.get('scheduled_report_date')
            if scheduled is not None:
                try:
                    if not isinstance(scheduled, str) or date.fromisoformat(scheduled).isoformat() != scheduled:
                        raise ValueError()
                except ValueError:
                    raise Problem('invalid_request')
            text = body['text']
            if not isinstance(text, str) or len(text) > 1000 or any(ord(ch) < 32 and ch not in '\n\t' for ch in text):
                raise Problem('invalid_request')
        else:
            raise Problem('invalid_request')
        body_hash = digest([class_id, kind, body])
        with self.connect() as c:
            c.execute('BEGIN IMMEDIATE')
            prior = c.execute('SELECT body_hash,result_json FROM orbit_report_admin_operations WHERE request_id=?', (request_id,)).fetchone()
            if prior:
                if not hmac.compare_digest(prior['body_hash'], body_hash):
                    raise Problem('request_id_conflict', 409)
                return json.loads(prior['result_json'])
            current = self._snapshot(c, class_id)
            if not hmac.compare_digest(current['revision'], body['expected_revision']):
                raise Problem('review_latest_choices', 409)
            now = datetime.now(timezone.utc).isoformat()
            affected = 0
            if kind == 'bulk-ai':
                affected = current['counts']['no_ai' if body['ai_enabled'] else 'ai']
                if affected != body['expected_affected_count']:
                    raise Problem('preview_changed', 409)
                cursor = c.execute('''UPDATE subscribers SET ai_enabled=?,updated_at=?
                  WHERE class_name=? AND status='active' AND ai_enabled IN(0,1) AND ai_enabled<>?
                  AND NOT EXISTS(SELECT 1 FROM signup_sessions p WHERE p.phone=subscribers.phone)
                  AND NOT EXISTS(SELECT 1 FROM orbit_student_controls a WHERE a.phone=subscribers.phone
                    AND (a.activity_status IS NULL OR a.activity_status<>'allowed'))''',
                  (body['ai_enabled'], now, name, body['ai_enabled']))
                if cursor.rowcount != affected:
                    raise Problem('preview_changed', 409)
            else:
                if not current['capabilities']['next_notice']:
                    raise Problem('notice_contract_unverified', 503)
                c.execute("UPDATE orbit_report_notices SET state='cancelled' WHERE class_id=? AND state='queued'", (class_id,))
                if body['text'].strip():
                    c.execute("INSERT INTO orbit_report_notices(id,class_id,text,state,created_at,scheduled_report_date) VALUES(?,?,?,'queued',?,?)",
                              (request_id, class_id, body['text'].strip(), now, scheduled))
            result = {'version': 1, 'request_id': request_id, 'class_id': class_id,
                'kind': kind, 'status': 'completed', 'affected_count': affected,
                'settings': self._snapshot(c, class_id)}
            c.execute('INSERT INTO orbit_report_admin_operations VALUES(?,?,?,?,?,?)',
                (request_id, class_id, kind, body_hash, json.dumps(result), now))
            return result

    def claim_notice(self, class_id, batch_id, recipients, *, forced=False, single=False, already_started=False, report_date=None):
        """Producer hook. One immutable class batch; forced/single sends never consume.

        It does not send. A verified sender must call only after report generation
        and media upload succeed, immediately before dispatch of the logical batch.
        """
        self.class_name(class_id)
        if forced or single or not self.notice_ready():
            return None
        if not isinstance(batch_id, str) or not 1 <= len(batch_id) <= 200:
            raise Problem('invalid_batch')
        if not isinstance(recipients, list) or not recipients or any(not isinstance(p, str) or not re.fullmatch(r'[1-9][0-9]{7,14}', p) for p in recipients) or len(recipients) != len(set(recipients)):
            raise Problem('invalid_recipients')
        with self.connect() as c:
            c.execute('BEGIN IMMEDIATE')
            prior = c.execute('SELECT * FROM orbit_report_notices WHERE class_id=? AND batch_id=?', (class_id, batch_id)).fetchone()
            if prior:
                return dict(prior)
            if c.execute('SELECT 1 FROM orbit_notice_batches WHERE class_id=? AND batch_id=?', (class_id, batch_id)).fetchone():
                return None
            c.execute('INSERT INTO orbit_notice_batches VALUES(?,?,NULL)', (class_id, batch_id))
            if already_started:
                return None
            queued = c.execute("SELECT * FROM orbit_report_notices WHERE class_id=? AND state='queued'", (class_id,)).fetchone()
            if not queued or (queued['scheduled_report_date'] and queued['scheduled_report_date'] != report_date):
                return None
            c.execute("UPDATE orbit_report_notices SET state='claimed',batch_id=? WHERE id=?", (batch_id, queued['id']))
            c.execute('UPDATE orbit_notice_batches SET notice_id=? WHERE class_id=? AND batch_id=?', (queued['id'], class_id, batch_id))
            c.executemany("INSERT INTO orbit_report_notice_targets VALUES(?,?,'pending')", [(queued['id'], phone) for phone in recipients])
            return dict(c.execute('SELECT * FROM orbit_report_notices WHERE id=?', (queued['id'],)).fetchone())

    def record_notice_result(self, notice_id, phone, outcome):
        if outcome not in ['accepted', 'failed', 'unknown', 'skipped_window_closed', 'skipped_window_unknown', 'skipped_report_failed', 'skipped_ineligible', 'skipped_report_date_unknown']:
            raise Problem('invalid_outcome')
        with self.connect() as c:
            c.execute('BEGIN IMMEDIATE')
            c.execute("UPDATE orbit_report_notice_targets SET outcome=? WHERE notice_id=? AND phone=? AND outcome='reserved'", (outcome, notice_id, phone))
            rows = c.execute('SELECT outcome FROM orbit_report_notice_targets WHERE notice_id=?', (notice_id,)).fetchall()
            if rows and all(r['outcome'] not in ['pending', 'reserved'] for r in rows):
                state = 'completed' if all(r['outcome'] == 'accepted' for r in rows) else 'partial' if any(r['outcome'] == 'accepted' for r in rows) else 'failed'
                c.execute('UPDATE orbit_report_notices SET state=? WHERE id=?', (state, notice_id))

    def reserve_notice_target(self, notice_id, phone):
        """At-most-once handoff. A timeout/crash never silently resends a notice."""
        with self.connect() as c:
            c.execute('BEGIN IMMEDIATE')
            notice = c.execute("SELECT text FROM orbit_report_notices WHERE id=? AND state='claimed'", (notice_id,)).fetchone()
            if not notice:
                return None
            changed = c.execute("UPDATE orbit_report_notice_targets SET outcome='reserved' WHERE notice_id=? AND phone=? AND outcome='pending'", (notice_id, phone)).rowcount
            return notice['text'] if changed == 1 else None


def register(app, owner_token, settings=None):
    from flask import jsonify, request
    if settings is None:
        from classera_report_notices import producer_ready
        settings = ReportSettings(notice_ready=producer_ready)
    settings.migrate()

    def handle(class_id=None, action=None, request_id=None):
        supplied = request.headers.get('Authorization', '')
        if not owner_token or not hmac.compare_digest(supplied.encode(), ('Bearer ' + owner_token).encode()):
            return jsonify(error='unauthorized'), 401
        if request.headers.get('Origin') or request.headers.get('Sec-Fetch-Site') == 'cross-site':
            return jsonify(error='owner_not_permitted'), 403
        try:
            if request.method == 'GET':
                if request.args:
                    raise Problem('invalid_request')
                if action == 'history':
                    result = settings.history()
                else:
                    result = settings.operation(class_id, request_id) if request_id else settings.snapshot(class_id)
            else:
                if request.content_length is None or request.content_length > 8192 or not request.is_json:
                    raise Problem('invalid_request')
                body = request.get_json(silent=True)
                if action == 'cancel':
                    if body != {}:
                        raise Problem('invalid_request')
                    result = settings.cancel_unresolved(class_id, request_id)
                else:
                    result = settings.preview(class_id, body) if action == 'preview' else settings.mutate(class_id, action, body)
            return jsonify(result), 200
        except Problem as error:
            return jsonify(error=error.code), error.status
        except (sqlite3.Error, OSError):
            return jsonify(error='report_settings_unavailable'), 503

    root = '/api/classera/report-settings/<class_id>'
    app.add_url_rule('/api/classera/report-settings/history', 'orbit_report_history',
                     handle, defaults={'action': 'history'}, methods=['GET'])
    app.add_url_rule(root, 'orbit_report_settings', handle, methods=['GET'])
    app.add_url_rule(root + '/bulk-ai/preview', 'orbit_report_ai_preview', handle, defaults={'action': 'preview'}, methods=['POST'])
    app.add_url_rule(root + '/bulk-ai/operations', 'orbit_report_ai_apply', handle, defaults={'action': 'bulk-ai'}, methods=['POST'])
    app.add_url_rule(root + '/next-notice', 'orbit_report_notice', handle, defaults={'action': 'next-notice'}, methods=['PUT'])
    app.add_url_rule(root + '/operations/<request_id>', 'orbit_report_operation', handle, methods=['GET'])
    app.add_url_rule(root + '/operations/<request_id>/cancel', 'orbit_report_cancel', handle, defaults={'action': 'cancel'}, methods=['POST'])

    @app.after_request
    def private_settings(response):
        if request.path.startswith('/api/classera/report-settings'):
            response.headers['Cache-Control'] = 'no-store'
        return response
