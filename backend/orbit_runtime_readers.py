"""Read-only service integration helpers. Never return upstream secrets."""
from datetime import datetime,timezone
from pathlib import Path
import requests
from logs_adapter import LogsAdapter

def checked_time(value):
    if isinstance(value,bool):return None
    try:
        if isinstance(value,(int,float)):
            return datetime.fromtimestamp(value,timezone.utc).isoformat()
        if isinstance(value,str) and len(value)<=40:
            datetime.fromisoformat(value.replace("Z","+00:00"));return value
    except (ValueError,TypeError,OverflowError,OSError):pass
    return None

def monitor_snapshot(loader,mapper,http=None):
    module=loader()
    client=http or requests.Session()
    # Existing password is used server-to-server only; no new login bypass.
    try:
        login=client.post("http://127.0.0.1:8080/login",
            data={"username":module.ADMIN_USER,"password":module.ADMIN_PASS},
            timeout=5,allow_redirects=False)
        if login.status_code not in (200,302):return {}
        response=client.get("http://127.0.0.1:8080/api/status",timeout=5,allow_redirects=False)
        if response.status_code!=200:return {}
        records=response.json()
        if not isinstance(records,list) or len(records)>1000:return {}
        result={}
        for index,record in enumerate(records,start=1):
            if not isinstance(record,dict):continue
            auth=record.get("auth") or {};manual=record.get("manual") or {}
            result["key-"+str(index)]={
                "status":mapper(record.get("state")),
                "lastAuthenticationCheck":checked_time(auth.get("checked")),
                "lastGenerationCheck":checked_time(manual.get("checked")),
                "enabled":record.get("enabled",True) is True,
            }
        return result
    except (requests.RequestException,ValueError,TypeError,AttributeError):return {}
    finally:
        if http is None:client.close()

def process_logs(processes,names,roots=("/home/local/.pm2/logs",)):
    allowed=set(names);registered={}
    resolved=[Path(root).resolve(strict=True) for root in roots]
    for process in processes:
        ident=process.get("pm_id");name=process.get("name")
        if type(ident) is not int or ident<0 or name not in allowed:continue
        env=process.get("pm2_env") or {};streams={}
        for stream,key in [("stdout","pm_out_log_path"),("stderr","pm_err_log_path")]:
            raw=env.get(key)
            if not isinstance(raw,str):continue
            try:
                path=Path(raw)
                if path.is_symlink():continue
                path=path.resolve(strict=True)
                if path.is_file() and any(path.is_relative_to(root) for root in resolved):streams[stream]=path
            except (OSError,ValueError):continue
        if streams:registered[ident]=streams
    return LogsAdapter(log_roots=roots,processes=registered,docker_readers={})
