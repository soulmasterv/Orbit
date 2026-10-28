"""Backed-up, narrowly scoped webhook/guard integration. Does not edit webhook configuration."""
import ast,os,shutil,sqlite3,time
from pathlib import Path

def patch_webhook(source):
    ast.parse(source)
    old='    data = request.get_json(silent=True) or {}'
    nodes=[n for n in ast.walk(ast.parse(source)) if isinstance(n,ast.FunctionDef) and n.name=="receive_webhook"]
    if len(nodes)!=1:raise RuntimeError("Webhook function changed")
    n=nodes[0];lines=source.splitlines(keepends=True);body="".join(lines[n.lineno-1:n.end_lineno])
    if old not in body or "kapso_message = data.get" not in body:raise RuntimeError("Webhook shape changed")
    replacement=old+'''
    from orbit_delivery_receipts import route_kapso_receipt
    if route_kapso_receipt(data, update_by_message_id):
        return jsonify({"status": "ok"}), 200
'''
    body=body.replace(old,replacement,1);lines[n.lineno-1:n.end_lineno]=[body]
    result="".join(lines);ast.parse(result);return result

def patch_guard(source):
    ast.parse(source);lines=source.splitlines(keepends=True)
    nodes=[n for n in ast.walk(ast.parse(source)) if isinstance(n,ast.FunctionDef) and n.name=="update_by_message_id"]
    if len(nodes)!=1:raise RuntimeError("Guard function changed")
    n=nodes[0];old="".join(lines[n.lineno-1:n.end_lineno])
    if "UPDATE deliveries" not in old or "observe_status" not in old:raise RuntimeError("Guard shape changed")
    new='''def update_by_message_id(message_id, status, event_at=None):
    status = str(status).lower()
    if status not in VALID_STATUSES:
        raise ValueError("Invalid delivery status")
    if not message_id:
        return False
    from orbit_delivery_receipts import advance_legacy
    with connect() as db:
        matched = advance_legacy(db, message_id, status)
    from orbit_classera_monitor import observe_status
    observe_status(message_id, status, event_at)
    return matched
'''
    lines[n.lineno-1:n.end_lineno]=[new];result="".join(lines);ast.parse(result);return result

def apply(stage):
    webhook=Path("/home/local/classera-webhook/app.py")
    guard=Path("/home/local/classera/shared/delivery_guard.py")
    patched=[(webhook,patch_webhook(webhook.read_text())),(guard,patch_guard(guard.read_text()))]
    backup=Path("/home/local/.local/state/orbit-fixes")/("delivery-receipts-"+time.strftime("%Y%m%dT%H%M%SZ",time.gmtime()))
    backup.mkdir(mode=0o700,parents=True,exist_ok=False)
    with sqlite3.connect("file:/home/local/classera/shared/delivery_state.db?mode=ro",uri=True) as source:
        with sqlite3.connect(backup/"delivery_state.db") as dest:source.backup(dest)
    os.chmod(backup/"delivery_state.db",0o600)
    for index,(target,text) in enumerate(patched):
        shutil.copy2(target,backup/(str(index)+"-"+target.name));os.chmod(backup/(str(index)+"-"+target.name),0o600)
    modules=[
      (Path("/home/local/classera/shared/orbit_delivery_receipts.py"),stage/"orbit_delivery_receipts.py"),
      (Path("/home/local/classera/shared/orbit_classera_monitor.py"),stage/"orbit_classera_monitor.py"),
      (Path("/home/local/ios-swift-app/orbit_classera_monitor.py"),stage/"orbit_classera_monitor.py")]
    for target,source in modules:
        text=source.read_text();compile(text,str(source),"exec")
        if target.exists():shutil.copy2(target,backup/("module-"+target.parent.name+"-"+target.name))
        tmp=target.with_suffix(".py.tmp");tmp.write_text(text);os.replace(tmp,target)
    for target,text in patched:
        tmp=target.with_suffix(".py.tmp");tmp.write_text(text);os.replace(tmp,target)
    print("Receipt-only hooks and monotonic updates installed with private backups; no messages sent.")

if __name__=="__main__":
    import argparse
    p=argparse.ArgumentParser();p.add_argument("--apply",action="store_true");args=p.parse_args()
    if args.apply:apply(Path(__file__).parent)
    else:raise SystemExit("Explicit --apply required")
