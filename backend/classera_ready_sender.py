"""Verified class-ready template adapter. Construction/GET never calls a provider.

Credentials stay in the existing private Kapso configuration. A local
verification receipt and explicit per-class enable flags are required to send.
"""
import hashlib
import json
from pathlib import Path
import re
import time
import requests

BODY = 'Your class {{1}} is now supported. Reply below to Opt-in.'
PAYLOAD = 'selfservice_optin'
CLASSES = {'12F': 'classera-1', '12E': 'classera-2'}
ROOT = Path('/home/local/classera')


def read_values(path):
    values = {}
    for line in Path(path).read_text().splitlines():
        line = line.strip()
        if not line or line.startswith('#'): continue
        key, sep, value = line.removeprefix('export ').partition('=')
        if sep: values[key.strip()] = value.strip().strip('\"\'')
    return values


def template_valid(template):
    if not isinstance(template, dict) or template.get('name') != 'classera_class_ready' or template.get('language') != 'en_US' or template.get('status') != 'APPROVED':
        return False
    components = template.get('components')
    if not isinstance(components, list) or any(not isinstance(c, dict) or c.get('type') not in ['HEADER', 'BODY', 'FOOTER', 'BUTTONS'] for c in components):
        return False
    bodies = [c for c in components if c.get('type') == 'BODY']
    buttons = [c for c in components if c.get('type') == 'BUTTONS']
    headers = [c for c in components if c.get('type') == 'HEADER']
    footers = [c for c in components if c.get('type') == 'FOOTER']
    return (len(bodies) == 1 and bodies[0].get('text') == BODY and len(buttons) == 1 and
        isinstance(buttons[0].get('buttons'), list) and len(buttons[0]['buttons']) == 1 and
        buttons[0]['buttons'][0].get('type') == 'QUICK_REPLY' and
        str(buttons[0]['buttons'][0].get('text', '')).lower() in ['opt-in', 'opt in'] and
        len(headers) <= 1 and all(c.get('format') == 'TEXT' and '{{' not in c.get('text', '') for c in headers) and
        len(footers) <= 1 and all('{{' not in c.get('text', '') for c in footers))


class ReadySender:
    def __init__(self, root=ROOT, receipt=None, post=requests.post, now=time.time):
        self.root = Path(root)
        self.receipt = Path(receipt) if receipt else self.root / 'shared/class_ready_contract.json'
        self.post, self.now = post, now

    def proof(self):
        try:
            proof = json.loads(self.receipt.read_text())
            config = read_values(self.root / 'shared/kapso.env')
            start, end = proof.get('verified_at'), proof.get('expires_at')
            phone = config.get('KAPSO_PHONE_NUMBER_ID', '')
            if (proof.get('version') != 1 or proof.get('callback_payload') != PAYLOAD or
                proof.get('callback_verified') is not True or proof.get('phone_id') != phone or
                not re.fullmatch(r'[0-9]{5,30}', phone) or not config.get('KAPSO_API_KEY') or
                type(start) not in [int, float] or not 0 < start <= self.now() or
                (end is not None and (type(end) not in [int, float] or end <= self.now())) or
                not template_valid(proof.get('template'))):
                return None
            base = config.get('KAPSO_API_BASE', '').rstrip('/')
            if base not in ['https://api.kapso.ai/meta/whatsapp', 'https://api.kapso.ai/meta/whatsapp/v24.0']:
                return None
            return proof, config
        except (OSError, ValueError, TypeError, AttributeError):
            return None

    def enabled(self, class_name):
        if class_name not in CLASSES or not self.proof(): return False
        try:
            values = read_values(self.root / CLASSES[class_name] / '.env')
            return (values.get('CLASSERA_CLASS') == class_name and values.get('WHATSAPP_PROVIDER') == 'kapso' and
                values.get('CLASSERA_CLASS_READY_TEMPLATE_ENABLED') == '1' and
                values.get('CLASSERA_CLASS_READY_TEMPLATE_NAME') == 'classera_class_ready' and
                values.get('CLASSERA_TEMPLATE_LANGUAGE') == 'en_US')
        except OSError: return False

    def catalog(self, original):
        def read():
            result = []
            proof = self.proof()
            revision = hashlib.sha256(json.dumps(proof[0]['template'], sort_keys=True).encode()).hexdigest() if proof else None
            for entry in original():
                row = dict(entry)
                row['template_verified'] = bool(row.get('supported') and self.enabled(row['id']))
                row['template_revision'] = revision if row['template_verified'] else None
                result.append(row)
            return result
        return read

    def send(self, class_name, phone):
        if not self.enabled(class_name) or not isinstance(phone, str) or not re.fullmatch(r'[1-9][0-9]{7,14}', phone):
            return {'status': 'failed'}
        current = self.proof()
        if not current: return {'status': 'failed'}
        _, config = current
        payload = {'messaging_product': 'whatsapp', 'to': phone, 'type': 'template', 'template': {
            'name': 'classera_class_ready', 'language': {'code': 'en_US'}, 'components': [
                {'type': 'body', 'parameters': [{'type': 'text', 'text': class_name}]},
                {'type': 'button', 'sub_type': 'quick_reply', 'index': '0',
                 'parameters': [{'type': 'payload', 'payload': PAYLOAD}]}]}}
        try:
            # Exact HTTPS origin, no redirects, retries or upstream-body logging.
            response = self.post('https://api.kapso.ai/meta/whatsapp/v24.0/' + config['KAPSO_PHONE_NUMBER_ID'] + '/messages',
                headers={'X-API-Key': config['KAPSO_API_KEY'], 'Content-Type': 'application/json'},
                json=payload, timeout=12, allow_redirects=False)
            if response.status_code == 408: return {'status': 'unknown'}
            if 400 <= response.status_code < 500: return {'status': 'failed'}
            if not 200 <= response.status_code < 300: return {'status': 'unknown'}
            value = response.json()
            messages = value.get('messages', [])
            message = messages[0].get('id') if isinstance(messages, list) and messages and isinstance(messages[0], dict) else None
            return {'status': 'accepted', 'message_id': message} if isinstance(message, str) and 0 < len(message) <= 500 else {'status': 'unknown'}
        except Exception:
            return {'status': 'unknown'}
