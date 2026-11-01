"""Next-report notice dispatch hooks. Never run a send during import or API GET.

At dispatch, plaintext requires verified current inbound-window evidence. Closed
or unknown windows require the approved classera_wa_notice/en_US template.
"""
import hashlib
import json
from pathlib import Path
import re
import time
from classera_kapso import Kapso
from classera_report_settings import ReportSettings

ROOT = Path('/home/local/classera')
CLASSES = {'12F': 'classera-1', '12E': 'classera-2'}


def producer_ready(root=ROOT):
    root = Path(root)
    try:
        receipt = json.loads((root / 'shared/orbit_report_notice_hooks.json').read_text())
        if receipt.get('version') != 1 or receipt.get('enabled') is not True:
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


def notice_template_valid(value):
    if not isinstance(value, dict) or value.get('name') != 'classera_wa_notice' or value.get('language') != 'en_US' or value.get('status') != 'APPROVED':
        return False
    components = value.get('components')
    if not isinstance(components, list) or any(not isinstance(c, dict) or c.get('type') not in ['BODY', 'HEADER', 'FOOTER'] for c in components):
        return False
    bodies = [c for c in components if c.get('type') == 'BODY']
    if len(bodies) != 1 or not isinstance(bodies[0].get('text'), str) or set(re.findall(r'\{\{([^}]+)\}\}', bodies[0]['text'])) != {'1'}:
        return False
    for component in components:
        if component['type'] == 'HEADER' and component.get('format') != 'TEXT': return False
        if component['type'] != 'BODY' and (not isinstance(component.get('text'), str) or '{{' in component['text']): return False
    return True


class NoticeTransport:
    def __init__(self, provider=None, root=ROOT, now=time.monotonic):
        self.provider = provider or Kapso(root=root)
        self.now = now
        self.cache = {}

    def template_ready(self, class_name):
        if class_name in self.cache and self.cache[class_name][0] > self.now():
            return self.cache[class_name][1]
        verified = False
        try:
            key, phone_id = self.provider.settings(class_name)
            response = self.provider.http.get('https://api.kapso.ai/platform/v1/whatsapp/phone_numbers',
                headers={'X-API-Key': key}, params={'phone_number_id': phone_id}, timeout=10, allow_redirects=False)
            if response.status_code != 200: return False
            matches = [row for row in response.json().get('data', []) if str(row.get('phone_number_id', row.get('id', ''))) == phone_id]
            if len(matches) != 1 or not re.fullmatch(r'[0-9]{5,30}', str(matches[0].get('business_account_id', ''))): return False
            account = str(matches[0]['business_account_id'])
            response = self.provider.http.get('https://api.kapso.ai/meta/whatsapp/v24.0/' + account + '/message_templates',
                headers={'X-API-Key': key}, params={'name': 'classera_wa_notice', 'language': 'en_US', 'limit': 10}, timeout=10, allow_redirects=False)
            if response.status_code == 200:
                verified = any(notice_template_valid(value) for value in response.json().get('data', []))
        except Exception:
            verified = False
        finally:
            self.cache[class_name] = (self.now() + 60, verified)
        return verified

    def send(self, phone, class_name, text, allowed=lambda: True):
        try:
            window = self.provider.window(phone, class_name)
        except Exception:
            window = {'window_open': None, 'seconds_left': None}
        remaining = window.get('seconds_left')
        if window.get('window_open') is True and type(remaining) is int and 30 <= remaining <= 86400:
            # One mutation only. A failed/uncertain plaintext is never retried as a template.
            try:
                if not allowed(): return 'skipped_ineligible'
                status, message = self.provider.send(phone, class_name, text)
                return status if status in ['accepted', 'failed', 'unknown'] else 'unknown'
            except Exception: return 'unknown'
        if not self.template_ready(class_name):
            return 'skipped_window_closed' if window.get('window_open') is False else 'skipped_window_unknown'
        try:
            key, phone_id = self.provider.settings(class_name)
            if not allowed(): return 'skipped_ineligible'
            response = self.provider.http.post('https://api.kapso.ai/meta/whatsapp/v24.0/' + phone_id + '/messages',
                headers={'X-API-Key': key, 'Content-Type': 'application/json'},
                json={'messaging_product': 'whatsapp', 'to': phone, 'type': 'template', 'template': {
                    'name': 'classera_wa_notice', 'language': {'code': 'en_US'}, 'components': [
                        {'type': 'body', 'parameters': [{'type': 'text', 'text': text}]}]}},
                timeout=12, allow_redirects=False)
            if response.status_code == 408: return 'unknown'
            if 400 <= response.status_code < 500: return 'failed'
            if not 200 <= response.status_code < 300: return 'unknown'
            messages = response.json().get('messages', [])
            return 'accepted' if messages and isinstance(messages[0].get('id'), str) and messages[0]['id'] else 'unknown'
        except Exception: return 'unknown'


class NoticeDispatch:
    def __init__(self, settings=None, transport=None, ready=producer_ready):
        self.ready = ready
        self.settings = settings or ReportSettings(notice_ready=ready)
        self.transport = transport or NoticeTransport()

    def prepare(self, class_name, report_title, recipients, *, single=False, forced=False, already_started=False):
        if class_name not in CLASSES or single or forced or not self.ready(): return None
        batch = hashlib.sha256(json.dumps([class_name, report_title], ensure_ascii=False).encode()).hexdigest()
        claimed = self.settings.claim_notice(CLASSES[class_name], batch, list(recipients), already_started=already_started)
        return {'notice_id': claimed['id'], 'class_name': class_name} if claimed else None

    def after_report(self, batch, phone, report_accepted):
        if not batch: return
        text = self.settings.reserve_notice_target(batch['notice_id'], phone)
        if text is None: return
        outcome = 'skipped_report_failed'
        if report_accepted:
            def eligible():
                with self.settings.connect(True) as c:
                    return bool(c.execute('''SELECT 1 FROM subscribers s
                      WHERE s.phone=? AND s.class_name=? AND s.status='active'
                      AND NOT EXISTS(SELECT 1 FROM signup_sessions p WHERE p.phone=s.phone)
                      AND NOT EXISTS(SELECT 1 FROM orbit_student_controls a WHERE a.phone=s.phone
                        AND (a.activity_status IS NULL OR a.activity_status<>'allowed'))''', (phone, batch['class_name'])).fetchone())
            outcome = self.transport.send(phone, batch['class_name'], text, allowed=eligible) if eligible() else 'skipped_ineligible'
        self.settings.record_notice_result(batch['notice_id'], phone, outcome)


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
