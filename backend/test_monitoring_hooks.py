import ast
import contextlib
import sys
import types
import unittest
from pathlib import Path
from unittest.mock import patch
from install_classera_monitoring import sender_patch, guard_patch, webhook_patch

SENDER = '''
import sys
from classera_access import can_reply as orbit_can_reply
def _post(payload):
    if not orbit_can_reply(payload.get("to")):
        raise RuntimeError("restricted")
    headers = dict(AUTH_HEADERS)
    return requests.post("https://mock.invalid/messages", headers=headers, json=payload, timeout=60)
def notify_all(report_title, ai_summary, pdf_path):
    from delivery_guard import reserve, update, get_status
    recipients = sorted(set(RECIPIENTS))
    if not recipients:
        raise RuntimeError("No recipients")
    pending = [p for p in recipients if get_status(report_title,p,CLASSERA_ID) is None]
    if not pending:
        return True
    for to in recipients:
        if not reserve(report_title,to,CLASSERA_ID):
                skipped += 1
                continue
        send_template(to)
    return True
def send_template(to):
    return _post({"to":to,"type":"template","template":{"name":"classera_v9"}})
'''
GUARD = '''
def update_by_message_id(message_id, status):
    status=str(status).lower()
    if status not in VALID_STATUSES: raise ValueError()
    if not message_id: return False
    with connect() as db:
        cursor=db.execute("UPDATE deliveries SET status=? WHERE message_id=?",(status,message_id))
        return cursor.rowcount > 0
'''
WEBHOOK = '''
def receive():
    return update_by_message_id(
        status_message_id,
        status_name,
    )
'''

def extracted(source,names,namespace):
    tree=ast.parse(source)
    nodes=[n for n in tree.body if isinstance(n,ast.FunctionDef) and n.name in names]
    exec(compile(ast.Module(body=nodes,type_ignores=[]),"offline_hooks","exec"),namespace)

class MonitoringHookTests(unittest.TestCase):
    def test_http_payload_and_restriction_gate_preserved(self):
        changed=sender_patch(SENDER)
        old=next(n for n in ast.walk(ast.parse(SENDER)) if isinstance(n,ast.Call) and ast.unparse(n.func)=="requests.post")
        new=next(n for n in ast.walk(ast.parse(changed)) if isinstance(n,ast.Call) and ast.unparse(n.func)=="requests.post")
        self.assertEqual(ast.dump(old),ast.dump(new))
        calls=[];observed=[]
        monitor=types.SimpleNamespace(before_send=lambda *a:observed.append(("before",a)) or "attempt",
                                      after_send=lambda *a:observed.append(("after",a)))
        response=object()
        ns={"orbit_can_reply":lambda p:True,"AUTH_HEADERS":{"X-API-Key":"fake-only"},
            "requests":types.SimpleNamespace(post=lambda *a,**kw:calls.append(kw) or response),"orbit_monitor":monitor}
        extracted(changed,["_post"],ns)
        payload={"to":"201000000001","type":"template","template":{"name":"classera_v9"}}
        self.assertIs(ns["_post"](payload),response)
        self.assertIs(calls[0]["json"],payload)
        self.assertEqual(len(calls),1);self.assertEqual(observed[0][1],("201000000001","classera_v9"))
        ns["orbit_can_reply"]=lambda p:False;calls.clear();observed.clear()
        with self.assertRaises(RuntimeError):ns["_post"](payload)
        self.assertEqual(calls,[]);self.assertEqual(observed,[])

    def test_network_error_is_observed_once_and_never_retried(self):
        changed=sender_patch(SENDER);calls=[];after=[]
        def fail(*a,**kw):calls.append(1);raise TimeoutError()
        ns={"orbit_can_reply":lambda p:True,"AUTH_HEADERS":{},
            "requests":types.SimpleNamespace(post=fail),
            "orbit_monitor":types.SimpleNamespace(before_send=lambda *a:"attempt",after_send=lambda *a:after.append(a))}
        extracted(changed,["_post"],ns)
        with self.assertRaises(TimeoutError):ns["_post"]({"to":"201000000001","type":"document"})
        self.assertEqual(calls,[1]);self.assertEqual(after,[("attempt",)])

    def test_early_webhook_is_observed_even_when_legacy_message_is_absent(self):
        changed=guard_patch(GUARD);observed=[]
        @contextlib.contextmanager
        def connection():yield types.SimpleNamespace(execute=lambda *a:types.SimpleNamespace(rowcount=0))
        fake=types.ModuleType("orbit_classera_monitor");fake.observe_status=lambda *a:observed.append(a)
        ns={"connect":connection,"VALID_STATUSES":{"delivered"}}
        extracted(changed,["update_by_message_id"],ns)
        with patch.dict(sys.modules,{"orbit_classera_monitor":fake}):
            self.assertFalse(ns["update_by_message_id"]("mock-message","delivered",1793010000))
        self.assertEqual(observed,[("mock-message","delivered",1793010000)])

    def test_webhook_passes_provider_timestamp_only(self):
        changed=webhook_patch(WEBHOOK)
        call=next(n for n in ast.walk(ast.parse(changed)) if isinstance(n,ast.Call) and isinstance(n.func,ast.Name) and n.func.id=="update_by_message_id")
        self.assertEqual(len(call.args),2)
        self.assertEqual([k.arg for k in call.keywords],["event_at"])
        self.assertEqual(ast.unparse(call.keywords[0].value),"status.get('timestamp')")
