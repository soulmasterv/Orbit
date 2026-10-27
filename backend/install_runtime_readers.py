"""Patch only known read functions after source validation; private backup required."""
import ast,os,shutil,time
from pathlib import Path

def patched(source):
    ast.parse(source);lines=source.splitlines(keepends=True);edits=[]
    replacements={
      "read_gemini":'''def read_gemini():
    from orbit_runtime_readers import monitor_snapshot
    values=monitor_snapshot(load_gemini_module,map_gemini_state)
    services_adapter.tests={identifier:gemini_test(int(identifier.split("-")[1]))
        for identifier,item in values.items() if item.get("enabled")}
    return values
''',
      "build_logs_adapter":'''def build_logs_adapter():
    from orbit_runtime_readers import process_logs
    return process_logs(pm2_raw(), set(APPROVED_LOG_PROCESSES.values()) | {
        "ADB","Change-Control","homelab-portal","school-webhook","school-api",
        "school-push","school-webpush","jarvis-phone-worker","phone-ADB",
        "jarvis-outgoing","jarvis-battery","jarvis-bluetooth-watch",
        "classera-2-scheduler","classera-fire-now"
    })
'''
    }
    for n in ast.parse(source).body:
        if isinstance(n,ast.FunctionDef) and n.name in replacements:
            old="".join(lines[n.lineno-1:n.end_lineno])
            if n.name=="read_gemini" and "gm.check_auth(record)" not in old:raise RuntimeError("Gemini reader changed; inspect before patching")
            if n.name=="build_logs_adapter" and "APPROVED_LOG_PROCESSES[pm_id]" not in old:raise RuntimeError("Logs reader changed; inspect before patching")
            edits.append((n.lineno-1,n.end_lineno,replacements.pop(n.name)))
        if isinstance(n,ast.FunctionDef) and n.name=="api_process_logs":
            old="".join(lines[n.lineno-1:n.end_lineno])
            if "logs_adapter.handle(" not in old:raise RuntimeError("Logs route changed")
            edits.append((n.lineno-1,n.end_lineno,old.replace("logs_adapter.handle(","build_logs_adapter().handle(")))
    if replacements or len(edits)!=3:raise RuntimeError("Expected runtime integration points not found")
    for start,end,replacement in sorted(edits,reverse=True):lines[start:end]=[replacement]
    result="".join(lines);ast.parse(result);return result

def apply(stage,root=Path("/home/local/ios-swift-app")):
    server=root/"server_control.py";source=server.read_text();result=patched(source)
    backup=Path("/home/local/.local/state/orbit-fixes")/("runtime-readers-"+time.strftime("%Y%m%dT%H%M%SZ",time.gmtime()))
    backup.mkdir(parents=True,mode=0o700,exist_ok=False)
    for name in ["server_control.py","services_adapter.py","orbit_runtime_readers.py"]:
        target=root/name
        if target.exists():shutil.copy2(target,backup/name);os.chmod(backup/name,0o600)
    for name in ["services_adapter.py","orbit_runtime_readers.py"]:
        text=(stage/name).read_text();compile(text,name,"exec")
        temp=root/(name+".tmp");temp.write_text(text);os.replace(temp,root/name)
    temp=root/"server_control.py.tmp";temp.write_text(result);os.replace(temp,server)
    print("Runtime readers updated with private backups; no provider tests or messages invoked.")

if __name__=="__main__":
    import argparse
    p=argparse.ArgumentParser();p.add_argument("--apply",action="store_true");args=p.parse_args()
    if args.apply:apply(Path(__file__).parent)
    else:raise SystemExit("Explicit --apply required")
