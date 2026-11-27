"""Next-report notice dispatch hooks. Never run a send during import or API GET.

Notices wait for a matching successful AI request. Only plaintext inside a
verified current inbound window is allowed; templates are never used.
"""
import hashlib
import json
from pathlib import Path
import re
import time
from datetime import date
from classera_kapso import Kapso
from classera_report_settings import ReportSettings

ROOT = Path('/home/local/classera')
CLASSES = {'12F': 'classera-1', '12E': 'classera-2'}


def report_date_label(title):
    match = re.search(r'(?:^|\D)(\d{1,2})[_/-](\d{1,2})[_/-](\d{4}|\d{2})(?:\D|$)', title)
    if not match: return None
    day, month, year = match.groups()
    try:
        value = date(2000 + int(year) if len(year) == 2 else int(year), int(month), int(day))
        return f'{value.day}/{value.month}/{value.year:04d}'
    except ValueError: return None


def producer_ready(root=ROOT):
    root = Path(root)
    try:
        receipt = json.loads((root / 'shared/orbit_report_notice_hooks.json').read_text())
        if receipt.get('version') != 1 or receipt.get('enabled') is not True:
            return False
        if receipt.get('notice_policy') != 'ai_request_window': return False
        webhook = root.parent / 'classera-webhook/app.py'
        if hashlib.sha256(webhook.read_bytes()).hexdigest() != receipt.get('ai_webhook'):
            return False
        for name, directory in CLASSES.items():
            expected = receipt.get('senders', {}).get(name)
            if not isinstance(expected, str) or not re.fullmatch(r'[a-f0-9]{64}', expected):
                return False
            if hashlib.sha256((root / directory / 'classeraAI/whatsapp_send.py').read_bytes()).hexdigest() != expected:
                return False
        return True
    except (OSError, ValueError, TypeError, AttributeError):
        return False


class NoticeTransport:
    def __init__(self, provider=None, root=ROOT, now=time.monotonic):
        self.provider = provider or Kapso(root=root)
        self.now = now
        self.cache = {}

    def send(self, phone, class_name, text, allowed=lambda: True, report_date=None):
        try:
            window = self.provider.window(phone, class_name)
        except Exception:
            window = {'window_open': None, 'seconds_left': None}
        remaining = window.get('seconds_left')
        if window.get('window_open') is True and type(remaining) is int and 30 <= remaining <= 86400:
            # One mutation only. A failed/uncertain plaintext is never retried as a template.
            try:
                if not allowed(): return 'skipped_ineligible'
                heading = f'*Notice for {class_name}' + (f' - {report_date}' if report_date else '') + ':*'
                status, message = self.provider.send(phone, class_name, heading + '\n\n- ' + text)
                return status if status in ['accepted', 'failed', 'unknown'] else 'unknown'
            except Exception: return 'unknown'
        return 'skipped_window_closed' if window.get('window_open') is False else 'skipped_window_unknown'


class NoticeDispatch:
    def __init__(self, settings=None, transport=None, ready=producer_ready):
        self.ready = ready
        self.settings = settings or ReportSettings(notice_ready=ready)
        self.transport = transport or NoticeTransport()

    def prepare(self, class_name, report_title, recipients, *, single=False, forced=False, already_started=False):
        if class_name not in CLASSES or single or forced or not self.ready(): return None
        batch = hashlib.sha256(json.dumps([class_name, report_title], ensure_ascii=False).encode()).hexdigest()
        label = report_date_label(report_title)
        report_date = None
        if label:
            day, month, year = map(int, label.split('/'))
            report_date = date(year, month, day).isoformat()
        claimed = self.settings.claim_notice(CLASSES[class_name], batch, list(recipients),
                                             already_started=already_started, report_date=report_date)
        return {'notice_id': claimed['id'], 'class_name': class_name, 'report_date': label} if claimed else None

    def eligible(self, phone, class_name):
        with self.settings.connect(True) as c:
            return bool(c.execute('''SELECT 1 FROM subscribers s
              WHERE s.phone=? AND s.class_name=? AND s.status='active' AND s.ai_enabled=1
              AND NOT EXISTS(SELECT 1 FROM signup_sessions p WHERE p.phone=s.phone)
              AND NOT EXISTS(SELECT 1 FROM orbit_student_controls a WHERE a.phone=s.phone
                AND (a.activity_status IS NULL OR a.activity_status<>'allowed'))''', (phone, class_name)).fetchone())

    def after_report(self, batch, phone, report_accepted):
        if not batch: return
        if report_accepted:
            # A report send never sends a notice. Keep the target pending for its AI request.
            with self.settings.connect() as c:
                c.execute("UPDATE orbit_report_notice_targets SET outcome='awaiting_ai' WHERE notice_id=? AND phone=? AND outcome='pending'", (batch['notice_id'], phone))
            return
        text = self.settings.reserve_notice_target(batch['notice_id'], phone)
        if text is not None: self.settings.record_notice_result(batch['notice_id'], phone, 'skipped_report_failed')

    def after_ai(self, phone, class_name, report_title):
        if class_name not in CLASSES: return
        batch_id = hashlib.sha256(json.dumps([class_name, report_title], ensure_ascii=False).encode()).hexdigest()
        with self.settings.connect() as c:
            c.execute('BEGIN IMMEDIATE')
            row = c.execute("SELECT id,text FROM orbit_report_notices WHERE class_id=? AND batch_id=? AND state='claimed'", (CLASSES[class_name], batch_id)).fetchone()
            if not row: return
            changed = c.execute("UPDATE orbit_report_notice_targets SET outcome='reserved' WHERE notice_id=? AND phone=? AND outcome IN ('pending','awaiting_ai')", (row['id'], phone)).rowcount
            if changed != 1: return
            ident, text = row['id'], row['text']
        eligible = lambda: self.eligible(phone, class_name)
        outcome = self.transport.send(phone, class_name, text, allowed=eligible, report_date=report_date_label(report_title)) if eligible() else 'skipped_ineligible'
        self.settings.record_notice_result(ident, phone, outcome)

_dispatch = None
def prepare(class_name, report_title, recipients, **options):
    global _dispatch
    try:
        if _dispatch is None: _dispatch = NoticeDispatch()
        return _dispatch.prepare(class_name, report_title, recipients, **options)
    except Exception:
        # Keep report generation/delivery working even when notice storage is unavailable.
        print('Report notice could not be prepared; normal report delivery continues.', flush=True)
        return None


def after_report(batch, phone, report_accepted):
    try:
        if batch and _dispatch: _dispatch.after_report(batch, phone, report_accepted)
    except Exception:
        print('Report notice outcome is unconfirmed; it will not be retried automatically.', flush=True)


def after_ai_request(message, class_name, *, delivery_path=ROOT / 'shared/delivery_state.db'):
    """Called only after the authenticated webhook successfully sends requested AI analysis.

    Exact recipient + outbound context + class ledger binding; no latest-report fallback.
    No pending notice is reserved unless a matching accepted report exists.
    """
    import sqlite3
    global _dispatch
    if class_name not in CLASSES or not isinstance(message, dict): return
    phone = message.get('from'); context = message.get('context')
    parent = context.get('id') if isinstance(context, dict) else None
    raw = message.get('timestamp')
    if not isinstance(phone, str) or not re.fullmatch(r'[1-9][0-9]{7,14}', phone): return
    if not isinstance(parent, str) or not 1 <= len(parent) <= 512: return
    if isinstance(raw, bool) or not re.fullmatch(r'[0-9]{1,12}', str(raw)): return
    age = time.time() - int(raw)
    if not 0 <= age <= 86340: return
    try:
        with sqlite3.connect(Path(delivery_path).resolve().as_uri() + '?mode=ro', uri=True) as c:
            row = c.execute("SELECT report FROM deliveries WHERE recipient=? AND message_id=? AND classera_id=? AND status IN ('accepted','sent','delivered','read') LIMIT 1", (phone, parent, CLASSES[class_name])).fetchone()
        if not row or not isinstance(row[0], str): return
        if _dispatch is None: _dispatch = NoticeDispatch()
        _dispatch.after_ai(phone, class_name, row[0])
    except Exception:
        print('Report notice could not be confirmed after AI request; no automatic retry.', flush=True)
