"""Incident-aware Orbit/SMS routing. No network or SMS sends in this module."""
import json
import re
import uuid

CATEGORIES = {
    'health': ('phone_service', 'error'), 'health_recovery': ('phone_service', 'recovery'),
    'companion_offline': ('companion_connection', 'error'),
    'companion_recovery': ('companion_connection', 'recovery'),
    'companion_health': ('companion_health', 'error'),
    'companion_health_recovery': ('companion_health', 'recovery'),
    'monitor_stale': ('health_monitor', 'error'), 'monitor_recovered': ('health_monitor', 'recovery'),
    'call': ('incoming_call', 'notice'), 'diaa_call': ('incoming_call', 'notice'),
}


def read(c, key, default=None):
    row = c.execute('SELECT value FROM alert_meta WHERE id=?', (key,)).fetchone()
    return json.loads(row[0]) if row else default


def put(c, key, value):
    c.execute('INSERT INTO alert_meta VALUES (?,?) ON CONFLICT(id) DO UPDATE SET value=excluded.value',
              (key, json.dumps(value)))


def init(c):
    c.execute('''CREATE TABLE IF NOT EXISTS phone_notification_incidents(
        id TEXT PRIMARY KEY, category TEXT NOT NULL, error_event TEXT, closed INTEGER NOT NULL DEFAULT 0,
        fallback_active INTEGER NOT NULL DEFAULT 0)''')
    c.execute('''CREATE TABLE IF NOT EXISTS phone_notification_history(
        event_id TEXT PRIMARY KEY, incident TEXT NOT NULL, category TEXT NOT NULL, phase TEXT NOT NULL,
        chosen TEXT NOT NULL, fallback INTEGER NOT NULL, actual TEXT, target TEXT,
        status TEXT NOT NULL, created REAL NOT NULL, summary TEXT NOT NULL)''')


def settings(c, delivery=None, fallback=None):
    if delivery is not None and delivery not in ('web', 'sms'):
        raise ValueError('Invalid phone alert delivery')
    if fallback is not None and type(fallback) is not bool:
        raise ValueError('Invalid phone alert fallback')
    if delivery is not None: put(c, 'phone_alert_delivery', delivery)
    if fallback is not None: put(c, 'phone_alert_fallback', fallback)
    return read(c, 'phone_alert_delivery', 'web'), read(c, 'phone_alert_fallback', True)


def brand(body):
    return re.sub(r'(?i)\bjarvis\b', 'Orbit', body)[:300]


def prepare(c, now):
    """Snapshot choices per incident; derive dispatch eligibility from durable receipts."""
    delivery, fallback = settings(c)
    events = c.execute('''SELECT e.* FROM alert_events e LEFT JOIN phone_notification_history h
        ON h.event_id=e.id WHERE h.event_id IS NULL ORDER BY e.created,e.rowid''').fetchall()
    for e in events:
        if e['kind'] not in CATEGORIES: continue
        category, phase = CATEGORIES[e['kind']]
        incident = None
        if phase in ('error', 'recovery'):
            incident = c.execute('SELECT * FROM phone_notification_incidents WHERE category=? AND closed=0 ORDER BY rowid DESC LIMIT 1',
                                 (category,)).fetchone()
        suppressed = False
        if phase=='recovery' and not incident:
            incident=c.execute('SELECT * FROM phone_notification_incidents WHERE category=? ORDER BY rowid DESC LIMIT 1',(category,)).fetchone()
            if incident: suppressed=True
        if phase == 'error' and incident: suppressed = True
        if incident:
            ident = incident['id']
            original = c.execute('SELECT chosen,fallback FROM phone_notification_history WHERE event_id=?',
                                 (incident['error_event'],)).fetchone()
            chosen, use_fallback = original['chosen'], original['fallback']
        else:
            ident, chosen, use_fallback = str(uuid.uuid4()), delivery, fallback
            c.execute('INSERT INTO phone_notification_incidents(id,category,error_event,closed) VALUES (?,?,?,?)',
                      (ident, category, e['id'] if phase == 'error' else None, int(phase != 'error')))
            if phase == 'recovery': suppressed = True
        if phase == 'recovery' or (phase == 'error' and e['expires'] <= now):
            c.execute('UPDATE phone_notification_incidents SET closed=1 WHERE id=?', (ident,))
        status = 'suppressed' if suppressed or e['expires'] <= now else 'pending'
        c.execute('INSERT INTO phone_notification_history VALUES (?,?,?,?,?,?,NULL,NULL,?,?,?)',
                  (e['id'], ident, category, phase, chosen, int(use_fallback), status, e['created'], brand(e['body'])))
    records = c.execute('''SELECT h.*,e.sms,e.push,e.dispatched,e.expires,e.kind FROM phone_notification_history h
                           JOIN alert_events e ON e.id=h.event_id ORDER BY h.created,h.rowid''').fetchall()
    # Receipts are refreshed before recoveries, regardless of event ordering.
    for r in records:
        if r['status'] == 'suppressed': continue
        actual, status = r['actual'], r['status']
        if r['push'] == 'accepted': actual, status = 'web', 'accepted'
        elif r['sms'] == 'delivered' and actual != 'web': actual, status = 'sms', 'delivered'
        elif r['sms'] == 'submitted' and actual != 'web': actual, status = 'sms', 'submitted'
        c.execute('UPDATE phone_notification_history SET actual=?,status=? WHERE event_id=?', (actual,status,r['event_id']))
    # If recovery SMS fails, move the whole incident to Orbit: resend its error there first.
    # This keeps the recovery on a channel that actually carried the linked error.
    diagnostic = read(c, 'orbit_companion_diagnostics', {})
    for r in records:
        if not fallback or r['chosen'] != 'sms' or not r['fallback'] or r['status'] == 'suppressed' or r['expires'] <= now: continue
        unavailable = r['kind']=='companion_offline' or diagnostic.get('sms_send_permission',diagnostic.get('sms_permissions')) is False or diagnostic.get('sim_ready') is False
        failed = r['sms'] in ('failed','unknown') or (r['dispatched'] is not None and now-r['dispatched']>=35 and r['sms'] not in ('submitted','delivered'))
        if unavailable or failed:
            c.execute('UPDATE phone_notification_incidents SET fallback_active=1 WHERE id=?', (r['incident'],))
    if not fallback:
        # Turning fallback off also stops an unsent fallback on an existing incident.
        c.execute("""UPDATE phone_notification_incidents SET fallback_active=0 WHERE id NOT IN
            (SELECT incident FROM phone_notification_history WHERE actual='web')""")
    for r in records:
        current = c.execute('SELECT * FROM phone_notification_history WHERE event_id=?', (r['event_id'],)).fetchone()
        target, status, actual = None, current['status'], current['actual']
        if status != 'suppressed' and not actual and r['expires'] <= now: status = 'expired'
        if status not in ('suppressed', 'expired'):
            target = current['chosen']
            fallback_active = c.execute('SELECT fallback_active FROM phone_notification_incidents WHERE id=?', (r['incident'],)).fetchone()[0]
            if r['phase'] == 'recovery':
                error = c.execute('''SELECT h.actual FROM phone_notification_incidents i JOIN phone_notification_history h
                    ON h.event_id=i.error_event WHERE i.id=?''', (r['incident'],)).fetchone()
                target = error['actual'] if error else None
                if fallback_active and target != 'web': target = None
                if not target: status = 'waiting_for_error'
            if fallback_active and r['phase'] != 'recovery':
                target = 'web'
                if actual != 'web':
                    status = 'fallback_pending'
                    c.execute("UPDATE alert_events SET push='pending',next_push=0,expires=MAX(expires,?) WHERE id=? AND push='not_needed'", (now+300,r['event_id']))
            elif actual: target = actual
            elif target == 'sms':
                diagnostic = read(c, 'orbit_companion_diagnostics', {})
                unavailable = r['kind'] == 'companion_offline' or diagnostic.get('sms_send_permission',diagnostic.get('sms_permissions')) is False or diagnostic.get('sim_ready') is False
                failed = r['sms'] in ('failed','unknown') or (r['dispatched'] is not None and now-r['dispatched'] >= 35)
                if unavailable or failed:
                    # Recovery never chooses a different channel from its error.
                    if fallback and r['fallback'] and r['phase'] != 'recovery': target, status = 'web', 'fallback_pending'
                    else: target, status = None, 'unavailable' if unavailable else 'failed' if r['sms']=='failed' else 'unconfirmed'
            elif target == 'web' and r['push'] in ('rejected','expired'): status = r['push']
        if not actual and target and status in ('waiting_for_error','unavailable','pending'):
            status = 'sending' if target=='sms' and r['dispatched'] is not None else 'pending'
        c.execute('UPDATE phone_notification_history SET target=?,status=? WHERE event_id=?', (target,status,r['event_id']))
        if r['dispatched'] is None:
            c.execute('UPDATE alert_events SET sms=? WHERE id=?', ('pending' if target=='sms' and not actual else 'web_only',r['event_id']))
        if target == 'sms' and actual == 'sms':
            c.execute("UPDATE alert_events SET push='not_needed' WHERE id=? AND push='pending'", (r['event_id'],))
        if status in ('suppressed','expired'):
            c.execute("UPDATE alert_events SET push='cancelled' WHERE id=? AND push='pending'", (r['event_id'],))


def route(c, event_id):
    return c.execute('SELECT * FROM phone_notification_history WHERE event_id=?', (event_id,)).fetchone()


def history(c, now):
    c.execute('''DELETE FROM phone_notification_history WHERE event_id NOT IN
        (SELECT event_id FROM phone_notification_history ORDER BY created DESC,rowid DESC LIMIT 200)
        AND event_id NOT IN (SELECT error_event FROM phone_notification_incidents WHERE closed=0 OR id IN
        (SELECT incident FROM phone_notification_history ORDER BY created DESC,rowid DESC LIMIT 200))''')
    c.execute('DELETE FROM phone_notification_incidents WHERE closed=1 AND id NOT IN (SELECT incident FROM phone_notification_history)')
    return [dict(row) for row in c.execute('''SELECT event_id,incident,category,phase,chosen,actual,status,created,summary
        FROM phone_notification_history ORDER BY created DESC,rowid DESC LIMIT 40''')]


def observe_monitor(c, now):
    health = read(c, 'health', {})
    if not health.get('at'): return
    stale = now-health['at'] > 75
    prior = read(c, 'phone_health_monitor_stale', False)
    if stale == prior: return
    put(c, 'phone_health_monitor_stale', stale)
    kind = 'monitor_stale' if stale else 'monitor_recovered'
    body = 'Orbit phone health monitor stopped checking in.' if stale else 'Orbit phone health monitoring recovered.'
    c.execute('INSERT INTO alert_events(id,kind,body,created,expires) VALUES (?,?,?,?,?)',
              (str(uuid.uuid4()),kind,body,now,now+300))
