"""Companion health transitions without message content or device identifiers."""
import json
import time
import uuid


def accept(connection, diagnostics, mode, now=None):
    if diagnostics is None:
        return
    if not isinstance(diagnostics, dict) or diagnostics.get('version') != 1:
        raise ValueError('Invalid companion diagnostics')
    fields = ('sms_permissions', 'sim_ready', 'forward_enabled')
    if any(type(diagnostics.get(field)) is not bool for field in fields):
        raise ValueError('Invalid companion diagnostics')
    now = time.time() if now is None else now
    def read(key, default):
        row = connection.execute('SELECT value FROM alert_meta WHERE id=?', (key,)).fetchone()
        return json.loads(row[0]) if row else default
    def write(key, value):
        connection.execute('INSERT INTO alert_meta VALUES (?,?) ON CONFLICT(id) DO UPDATE SET value=excluded.value', (key, json.dumps(value)))
    needed = diagnostics['forward_enabled'] or mode == 'sms'
    issues = []
    if needed and not diagnostics['sms_permissions']:
        issues.append('SMS permissions are missing')
    if needed and not diagnostics['sim_ready']:
        issues.append('The sending SIM is unavailable')
    write('orbit_companion_diagnostics', dict(diagnostics, at=now))
    state = '|'.join(issues)
    pending = read('orbit_companion_health_pending', {'state': '', 'at': now})
    if pending['state'] != state:
        pending = {'state': state, 'at': now}
        write('orbit_companion_health_pending', pending)
    reported = read('orbit_companion_health_reported', '')
    if state == reported or now - pending['at'] < 30:
        return
    if state:
        body = 'Orbit Phone needs attention. ' + '. '.join(issues) + '. Open the companion settings.'
        kind = 'companion_health'
    else:
        body = 'Orbit Phone SMS permissions and SIM checks recovered.'
        kind = 'companion_health_recovery'
    connection.execute(
        "INSERT INTO alert_events(id,kind,body,created,expires,sms) VALUES (?,?,?,?,?,'web_only')",
        (str(uuid.uuid4()), kind, body, now, now + 3600)
    )
    write('orbit_companion_health_reported', state)


def pairing_payload(home):
    """Called only after Orbit's owner authentication, never from the public poll."""
    import sqlite3
    key = (home / 'school-bot/secrets/jarvis-phone-alerts.key').read_text().strip()
    with sqlite3.connect(f'file:{home / "jarvis-phone-integration/phone-alerts.db"}?mode=ro', uri=True) as connection:
        row = connection.execute('SELECT value FROM alert_meta WHERE id=?', ('paired',)).fetchone()
    if len(key) != 64 or any(char not in '0123456789abcdef' for char in key) or not row:
        raise ValueError('Pairing not configured')
    device = str(uuid.UUID(json.loads(row[0])))
    return {'format': 'orbit-phone-pairing', 'version': 1, 'key': key, 'device': device}
