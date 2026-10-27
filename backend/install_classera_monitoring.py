"""Stage minimal monitoring-only hooks. Apply explicitly after tests; never invokes a sender."""
import ast
import hashlib
import json
import os
import shutil
import sqlite3
import sys
from datetime import datetime, timezone
from pathlib import Path

ROOT=Path("/home/local")
STAGE=ROOT/"orbit-monitor-stage"
TARGETS=[
 ROOT/"classera/classera-1/classeraAI/whatsapp_send.py",
 ROOT/"classera/classera-2/classeraAI/whatsapp_send.py",
 ROOT/"classera/shared/delivery_guard.py",
 ROOT/"classera-webhook/app.py",
 ROOT/"ios-swift-app/classera_students.py"]

def sender_patch(source):
    if "import orbit_classera_monitor as orbit_monitor" in source:raise ValueError("Hooks already installed; inspect current code")
    tree=ast.parse(source)
    import_node=next(n for n in tree.body if isinstance(n,ast.ImportFrom) and n.module=="classera_access")
    lines=source.splitlines(keepends=True);lines.insert(import_node.end_lineno,"import orbit_classera_monitor as orbit_monitor\n")
    source="".join(lines);tree=ast.parse(source)
    post=next(n for n in tree.body if isinstance(n,ast.FunctionDef) and n.name=="_post")
    original=ast.get_source_segment(source,post)
    call=next(n for n in ast.walk(post) if isinstance(n,ast.Return) and isinstance(n.value,ast.Call) and ast.unparse(n.value.func)=="requests.post")
    request=ast.get_source_segment(source,call).replace("return requests.post(","response = requests.post(",1)
    wrapped="    attempt = orbit_monitor.before_send(payload.get('to'), payload.get('template', {}).get('name')) if payload.get('type') in ('template', 'document') else None\n    try:\n"
    wrapped+="\n".join("        "+line if index==0 else "    "+line for index,line in enumerate(request.splitlines()))
    wrapped+="\n    except Exception:\n        orbit_monitor.after_send(attempt)\n        raise\n    orbit_monitor.after_send(attempt, response)\n    return response"
    # Replace the final HTTP return only. Original restriction guard/headers/payload remain intact.
    old_lines=original.splitlines()
    offset=call.lineno-post.lineno
    replacement="\n".join(old_lines[:offset])+"\n"+wrapped
    source=source.replace(original,replacement,1)
    marker="    if not recipients:\n"
    assert source.count(marker)==1
    source=source.replace(marker,"    orbit_monitor.begin_report(report_title, CLASSERA_CLASS, recipients, forced=os.getenv('FORCE_SEND') == '1')\n\n"+marker,1)
    source=source.replace('    if not pending:\n','    if not pending:\n        for to in recipients: orbit_monitor.record_skip(to)\n',1)
    source=source.replace('                skipped += 1\n','                orbit_monitor.record_skip(to)\n                skipped += 1\n',1)
    ast.parse(source)
    return source

def guard_patch(source):
    tree=ast.parse(source);node=next(n for n in tree.body if isinstance(n,ast.FunctionDef) and n.name=="update_by_message_id")
    old=ast.get_source_segment(source,node)
    assert "event_at" not in old and "return cursor.rowcount > 0" in old
    new=old.replace("def update_by_message_id(message_id, status):","def update_by_message_id(message_id, status, event_at=None):")
    new=new.replace("        return cursor.rowcount > 0","        matched = cursor.rowcount > 0")
    new+="\n\n    from orbit_classera_monitor import observe_status\n    observe_status(message_id, status, event_at)\n    return matched"
    source=source.replace(old,new,1);ast.parse(source);return source

def webhook_patch(source):
    import re
    tree=ast.parse(source)
    calls=[n for n in ast.walk(tree) if isinstance(n,ast.Call) and isinstance(n.func,ast.Name) and n.func.id=="update_by_message_id"]
    assert len(calls)==1 and not calls[0].keywords
    old=ast.get_source_segment(source,calls[0])
    indent=re.search(r"\n( +)status_name",old)[1]
    new=old.replace("status_name,","status_name,\n"+indent+'event_at=status.get("timestamp"),',1)
    source=source.replace(old,new,1);ast.parse(source);return source

def student_patch(source):
    marker="    @app.after_request\n"
    assert marker in source and "register_monitoring" not in source
    return source.replace(marker,"    from classera_monitoring_api import register as register_monitoring\n    register_monitoring(app, owner_token)\n\n"+marker,1)

def stage():
    folder=STAGE/"patched";folder.mkdir(parents=True,exist_ok=True,mode=0o700)
    manifest=[]
    for index,target in enumerate(TARGETS):
        original=target.read_text()
        if target.name=="whatsapp_send.py":updated=sender_patch(original)
        elif target.name=="delivery_guard.py":updated=guard_patch(original)
        elif target.name=="app.py":updated=webhook_patch(original)
        else:updated=student_patch(original)
        ast.parse(updated)
        output=folder/(str(index)+".py");output.write_text(updated)
        manifest.append({"target":str(target),"source":str(output),"sha":hashlib.sha256(target.read_bytes()).hexdigest()})
    (folder/"manifest.json").write_text(json.dumps(manifest))
    print("Monitoring-only hooks staged:",len(manifest))

def apply():
    manifest=json.loads((STAGE/"patched/manifest.json").read_text())
    assert [Path(v["target"]) for v in manifest]==TARGETS
    for entry in manifest:
        assert hashlib.sha256(Path(entry["target"]).read_bytes()).hexdigest()==entry["sha"], "Live source changed; restage and test"
    backup=ROOT/".local/state/orbit-fixes"/("monitoring-"+datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ"))
    backup.mkdir(parents=True,mode=0o700);os.chmod(backup,0o700)
    db=ROOT/"classera/shared/delivery_state.db"
    src=sqlite3.connect(db.resolve().as_uri()+"?mode=ro",uri=True);dest=sqlite3.connect(backup/"delivery_state.db")
    src.backup(dest);src.close();dest.close();os.chmod(backup/"delivery_state.db",0o600)
    for index,entry in enumerate(manifest):
        shutil.copy2(entry["target"],backup/(str(index)+".py"));os.chmod(backup/(str(index)+".py"),0o600)
    for directory in [ROOT/"classera/shared",ROOT/"ios-swift-app"]:
        shutil.copy2(STAGE/"orbit_classera_monitor.py",directory/"orbit_classera_monitor.py")
    shutil.copy2(STAGE/"classera_monitoring_api.py",ROOT/"ios-swift-app/classera_monitoring_api.py")
    sys.path.insert(0,str(STAGE))
    from orbit_classera_monitor import Store
    Store().migrate()
    for entry in manifest:
        target=Path(entry["target"]);temporary=target.with_name(target.name+".orbit-monitoring.tmp")
        temporary.write_bytes(Path(entry["source"]).read_bytes())
        os.chmod(temporary,target.stat().st_mode & 0o777)
        os.replace(temporary,target)
    print("Installed additive monitoring; original source/database backup:",backup)
    print("No sender, scheduler, template, subscriber update or FORCE_SEND activation was invoked.")

if __name__=="__main__":
    if len(sys.argv)!=2 or sys.argv[1] not in ["stage","apply"]:raise SystemExit("Use stage or apply")
    globals()[sys.argv[1]]()
