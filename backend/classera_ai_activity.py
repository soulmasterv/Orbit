"""Append-only button evidence, called only by the authenticated webhook.

No provider calls, bot preference changes, source text, or AI-response content.
Migration and webhook hook installation require explicit production approval.
"""
import re
import sqlite3
import time
from pathlib import Path

DB = Path('/home/local/classera/shared/delivery_state.db')


def migrate(connection, now=None):
    connection.executescript('''
      CREATE TABLE IF NOT EXISTS orbit_ai_button_tracking(
        version INTEGER PRIMARY KEY CHECK(version=1), started_at INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS orbit_ai_button_events(
        event_id TEXT PRIMARY KEY,phone TEXT NOT NULL,parent_message_id TEXT NOT NULL,
        requested_at INTEGER NOT NULL,received_at INTEGER NOT NULL);
      CREATE INDEX IF NOT EXISTS orbit_ai_button_parent ON orbit_ai_button_events(parent_message_id,phone);
    ''')
    connection.execute('INSERT OR IGNORE INTO orbit_ai_button_tracking VALUES(1,?)',
                       (int(time.time()) if now is None else now,))


def is_ai_button(message):
    kind = message.get('type')
    if kind not in ('button', 'interactive'):
        return False
    if kind == 'button':
        button = message.get('button')
    else:
        interactive = message.get('interactive')
        button = interactive.get('button_reply') if isinstance(interactive, dict) else None
    kapso = message.get('kapso')
    details = kapso.get('message_type_data') if isinstance(kapso, dict) else None
    if not isinstance(button, (dict, str)) and isinstance(details, dict):
        button = details.get('button_reply')
        if button is None and kind == 'button':
            button = details.get('button', details)
    values = (button,) if isinstance(button, str) else (
        (button.get(field) for field in ('id', 'payload', 'text', 'title'))
        if isinstance(button, dict) else ()
    )
    return any(isinstance(value, str) and value.strip().casefold() == 'get ai analysis'
               for value in values)


def observe_button(message, *, path=DB, now=None):
    """Best-effort audit; never interrupts existing webhook actions.

    Entry-point call sites must be real inbound button branches, not the shared
    handle_ai_button handler also used for synthetic typed-text AI requests.
    """
    if not isinstance(message, dict) or not is_ai_button(message): return False
    context = message.get('context')
    if not isinstance(context, dict): return False
    phone, event, parent = message.get('from'), message.get('id'), context.get('id')
    if not isinstance(phone, str) or not re.fullmatch(r'[1-9][0-9]{7,14}', phone): return False
    if any(not isinstance(v, str) or not v or len(v) > 512 or any(ord(c) < 32 for c in v) for v in [event, parent]): return False
    raw = message.get('timestamp')
    if isinstance(raw, bool) or not isinstance(raw, (int, str)) or not re.fullmatch(r'[0-9]{1,12}', str(raw)): return False
    received = int(time.time()) if now is None else now
    requested = int(raw)
    if requested <= 0 or requested > received + 300: return False
    try:
        with sqlite3.connect(Path(path).resolve().as_uri() + '?mode=rw', uri=True, timeout=1) as c:
            # No lazy migration during a request; absent installation fails safely.
            if not c.execute('SELECT 1 FROM orbit_ai_button_tracking WHERE version=1').fetchone(): return False
            c.execute('INSERT OR IGNORE INTO orbit_ai_button_events VALUES(?,?,?,?,?)',
                      (event, phone, parent, requested, received))
            row = c.execute('SELECT phone,parent_message_id,requested_at FROM orbit_ai_button_events WHERE event_id=?', (event,)).fetchone()
            return row == (phone, parent, requested)
    except (sqlite3.Error, OSError, ValueError): return False


def evidence(connection, attempt):
    """Read only. Exact outbound context + phone; never latest-report guessing."""
    unknown = {'status': 'unknown', 'requested_at': None}
    try:
        coverage = connection.execute('SELECT started_at FROM orbit_ai_button_tracking WHERE version=1').fetchone()
        if not coverage: return unknown
        click = connection.execute('''SELECT MIN(requested_at) FROM orbit_ai_button_events
          WHERE phone=? AND parent_message_id=?''', (attempt['phone'], attempt['message_id'])).fetchone()
        if click and click[0]: return {'status': 'requested', 'requested_at': click[0]}
        # Absence is labelled "No click recorded", never proof the student did not press.
        if not attempt['historical'] and attempt['created_at'] and attempt['created_at'] >= coverage[0]:
            return {'status': 'not_recorded', 'requested_at': None}
    except sqlite3.Error: pass
    return unknown

