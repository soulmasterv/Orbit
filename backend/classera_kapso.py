"""Shared Classera Kapso transport. No requests occur during import."""
from datetime import datetime, timezone
from pathlib import Path
import time
import re
import requests

def read_env(path):
    result = {}
    try:
        for line in Path(path).read_text().splitlines():
            if line.strip() and not line.lstrip().startswith('#') and '=' in line:
                key, value = line.split('=', 1); result[key.strip()] = value.strip().strip("'\"")
    except OSError: pass
    return result

class MessageProblem(Exception):
    def __init__(self,code,status=503):self.code,self.status=code,status

class Kapso:
    def __init__(self,http=None,root='/home/local/classera'):
        self.http=http or requests.Session()
        self.root=Path(root)
    def settings(self,klass):
        number={"12F":"1","12E":"2"}.get(klass)
        if not number:raise MessageProblem("invalid_class",422)
        config=read_env(self.root/("classera-"+number)/".env")
        shared=read_env(self.root/"shared/kapso.env")
        if config.get("WHATSAPP_PROVIDER")!="kapso" or config.get("CLASSERA_CLASS")!=klass:
            raise MessageProblem("provider_unavailable")
        key,identifier=shared.get("KAPSO_API_KEY"),shared.get("KAPSO_PHONE_NUMBER_ID")
        if not key or not identifier or not re.fullmatch(r"[0-9]+",identifier):raise MessageProblem("provider_unavailable")
        return key,identifier
    def window(self,phone,klass):
        key,identifier=self.settings(klass)
        rows=[];after=None
        for page in range(5):
            params={"phone_number":phone,"limit":100,"fields":"kapso(last_inbound_at)"}
            if after:params["after"]=after
            try:
                response=self.http.get("https://api.kapso.ai/meta/whatsapp/v24.0/"+identifier+"/conversations",
                    headers={"X-API-Key":key},params=params,timeout=10,allow_redirects=False)
                if response.status_code!=200:raise MessageProblem("window_unavailable")
                body=response.json()
                if not isinstance(body,dict) or not isinstance(body.get("data"),list):raise MessageProblem("window_unavailable")
                rows.extend(body["data"])
                paging=body.get("paging") or {}
                if not paging.get("next"):break
                cursor=(paging.get("cursors") or {}).get("after")
                if not isinstance(cursor,str) or not cursor or cursor==after:raise MessageProblem("window_unavailable")
                after=cursor
            except (requests.RequestException,ValueError,TypeError):raise MessageProblem("window_unavailable")
        else:raise MessageProblem("window_unavailable")
        now=int(time.time());times=[]
        for row in rows:
            if not isinstance(row,dict):raise MessageProblem("window_unavailable")
            if str(row.get("phone_number","")).lstrip("+")!=phone or str(row.get("phone_number_id",""))!=identifier:continue
            raw=(row.get("kapso") or {}).get("last_inbound_at")
            if not raw:continue
            try:
                value=datetime.fromisoformat(str(raw).replace("Z","+00:00"))
                if value.tzinfo is None:raise ValueError()
                value=int(value.timestamp())
                if value>now:raise ValueError()
                times.append(value)
            except (ValueError,TypeError,OverflowError):raise MessageProblem("window_unavailable")
        inbound=max(times) if times else None
        seconds=max(0,min(86400,inbound+86400-now)) if inbound else None
        return {"class_name":klass,"window_open":seconds>0 if seconds is not None else None,
                "seconds_left":seconds,"last_inbound_at":inbound}
    def send(self,phone,klass,text):
        key,identifier=self.settings(klass)
        response=self.http.post("https://api.kapso.ai/meta/whatsapp/v24.0/"+identifier+"/messages",
            headers={"X-API-Key":key,"Content-Type":"application/json"},
            json={"messaging_product":"whatsapp","recipient_type":"individual","to":phone,
                  "type":"text","text":{"body":text,"preview_url":False}},
            timeout=15,allow_redirects=False)
        if 400<=response.status_code<500:return "failed",None
        if not 200<=response.status_code<300:return "unknown",None
        try:
            identifier=response.json()["messages"][0]["id"]
            if isinstance(identifier,str) and identifier:return "accepted",identifier
        except (KeyError,ValueError,TypeError,IndexError):pass
        return "unknown",None


