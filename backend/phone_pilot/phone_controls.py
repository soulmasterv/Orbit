"""Restricted adapters for the Orbit phone pilot."""
import http.client
import json
import re
import time
from pathlib import Path

ROOT = Path.home()
PHONE = ROOT / 'jarvis-phone-integration'
PAUSE = PHONE / 'orbit-answering-pause.json'
CAPABILITIES = PHONE / 'orbit-phone-capabilities.json'
ALERT_CONFIG = ROOT / 'school-bot/secrets/jarvis-phone-alerts.json'
WHATSAPP_CONFIG = ROOT / 'jarvis/whatsapp-secrets/config.json'


def capability(name):
    try:
        return json.loads(CAPABILITIES.read_text()).get(name) is True
    except (OSError, ValueError, AttributeError):
        return False


def read_pause():
    try:
        until = json.loads(PAUSE.read_text())['until']
    except FileNotFoundError:
        return None
    except (OSError, ValueError, TypeError, KeyError):
        return {'until': None}
    if until is None:
        return {'until': None}
    if type(until) not in (int, float):
        return {'until': None}
    return {'until': until} if until > time.time() else None


def answering_paused():
    return read_pause() is not None


def set_pause(minutes):
    if minutes == 0:
        PAUSE.unlink(missing_ok=True)
        return
    until = None if minutes is None else time.time() + minutes * 60
    tmp = PAUSE.with_suffix('.tmp')
    tmp.write_text(json.dumps({'until': until}))
    tmp.chmod(0o600)
    tmp.replace(PAUSE)


def local_request(port, key_file, path, payload):
    if key_file.stat().st_mode & 0o077:
        raise PermissionError('Unsafe key permissions')
    key = key_file.read_text().strip()
    conn = http.client.HTTPConnection('127.0.0.1', port, timeout=8)
    try:
        conn.request('POST', path, json.dumps(payload), {
            'Authorization': 'Bearer ' + key, 'Content-Type': 'application/json'
        })
        response = conn.getresponse()
        data = response.read(32769)
        if len(data) > 32768:
            raise ValueError('Response too large')
        return response.status, json.loads(data)
    finally:
        conn.close()


def call_queue(job_id=None):
    path = '/internal/call-jobs/orbit-queue' if job_id is None else '/internal/call-jobs/orbit-cancel'
    body = {} if job_id is None else {'id': job_id}
    return local_request(18083, ROOT / 'jarvis/phone/key', path, body)


def destination(channel):
    try:
        if channel == 'sms':
            number = json.loads(ALERT_CONFIG.read_text()).get('recipient')
        else:
            config = json.loads(WHATSAPP_CONFIG.read_text())
            number = config.get('notificationRecipient')
            if not number:
                source = (ROOT / 'jarvis/whatsapp-adapter/main.mjs').read_text()
                match = re.search(r"config\.notificationRecipient\|\|'([0-9]{8,15})'", source)
                number = match.group(1) if match else None
            if number not in config.get('owners', []):
                return None
        return number if isinstance(number, str) and re.fullmatch(r'\+?[0-9]{8,15}', number) else None
    except (OSError, ValueError, AttributeError):
        return None


def send_whatsapp(ident, body, recipient):
    status, result = local_request(
        18085, ROOT / 'jarvis/whatsapp-secrets/gateway.key',
        '/notify', {'id': ident, 'body': body, 'expectedRecipient': recipient}
    )
    return 'accepted' if status == 200 and result.get('status') == 'accepted' else 'unknown'
