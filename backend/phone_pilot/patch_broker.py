"""Guarded integration into the existing phone broker; fails on source drift."""
from pathlib import Path
import ast


def patch(source):
    def replace(old, new):
        nonlocal source
        if source.count(old) != 1: raise ValueError('Broker source changed near: ' + old[:75])
        source = source.replace(old, new)
    replace('def meta(c,k,default=None):', 'import phone_notifications as notifications\n\ndef meta(c,k,default=None):')
    replace('    c.commit();c.close()\n    os.chmod(DB,0o600)', '    notifications.init(c)\n    c.commit();c.close()\n    os.chmod(DB,0o600)')
    replace('diagnostics=None):', 'diagnostics=None,phone_delivery=None,phone_fallback=None):')
    replace("        if mode!='sms':c.execute(\"UPDATE alert_events SET sms='web_only' WHERE sms='pending' AND dispatched IS NULL\")", '        delivery,fallback=notifications.settings(c,phone_delivery,phone_fallback)')
    replace('        accept(c, diagnostics, mode, now)', '        accept(c, diagnostics, delivery, now)')
    replace('        jobs=[]', '        notifications.prepare(c,now)\n        jobs=[]')
    replace("'expires':row['expires']})", "'expires':row['expires'],'phone_alert':notifications.route(c,row['id']) is not None})")
    replace("'phone_control':control}", "'phone_control':control,'phone_delivery':delivery,'phone_fallback':fallback,'notification_history':notification_history}")
    replace("        c.commit();return {'jobs':jobs", "        notification_history=notifications.history(c,now)\n        c.commit();return {'jobs':jobs")
    replace("diagnostics=value.get('diagnostics'))", "diagnostics=value.get('diagnostics'),phone_delivery=value.get('phone_delivery'),phone_fallback=value.get('phone_fallback'))")
    replace("send('health','JARVIS phone service checks have recovered.',300)", "send('health_recovery','Orbit phone service checks have recovered.',300)")
    replace("        mode=meta(c,'notification_mode','web')\n        rows=", "        mode=meta(c,'notification_mode','web')\n        notifications.observe_monitor(c,now)\n        notifications.prepare(c,now)\n        rows=")
    replace("        event_mode='web' if offline or row['kind'] in ('orbit_test_web','companion_health','companion_health_recovery') else mode",
            "        with connect() as c:route=notifications.route(c,row['id'])\n"
            "        if route is not None:\n"
            "            if route['target']!='web' or route['actual']=='web':continue\n"
            "            event_mode='web'\n"
            "        else:event_mode='web' if row['kind']=='orbit_test_web' else mode")
    replace("(state,now+delay,row['id']))", "(state,now+delay,row['id']))\n            notifications.prepare(c,now)")
    replace("            if accepted:\n                ident=str(uuid.uuid4())", "            if active:\n                ident=str(uuid.uuid4())")
    replace("'body':row['body'],'event_id'", "'body':notifications.brand(row['body']),'event_id'")
    replace("('Diaa' if row['kind']=='diaa_call' else 'Missed Call Keeper' if row['kind']=='call' else 'Orbit')", "('Orbit: Diaa' if row['kind']=='diaa_call' else 'Orbit: Incoming call' if row['kind']=='call' else 'Orbit')")
    replace("        if row['sms']=='delivered' or row['wa']=='accepted':continue", "        if route is None and (row['sms']=='delivered' or row['wa']=='accepted'):continue")
    ast.parse(source)
    return source


if __name__ == '__main__':
    import sys
    Path(sys.argv[2]).write_text(patch(Path(sys.argv[1]).read_text(encoding='utf-8')), encoding='utf-8')
