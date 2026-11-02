"""Read-only labels and Classera evidence. Never return keys or fingerprints."""
import hashlib,json,re,sqlite3
from datetime import datetime,timedelta
from pathlib import Path
from zoneinfo import ZoneInfo
from ai_key_usage import configured_keys,Unavailable as PoolUnavailable

def safe_label(value,secrets=()):
    if not isinstance(value,str):return None
    value=value.strip()
    if not value or len(value)>64 or not re.fullmatch(r'[\w .():&/+@-]+',value):return None
    if re.search(r'AIza|bearer|secret|token|password',value,re.I):return None
    if any(isinstance(key,str) and len(key)>=6 and key in value for key in secrets):return None
    return value

def build_metadata(status_records, path=Path('/home/local/gemini-api/keys.json'),
                   usage_path=Path('/home/local/classera/shared/ai_usage.db'), pools=configured_keys,
                   now=lambda:datetime.now(ZoneInfo('Africa/Cairo'))):
    try:
        records=json.loads(Path(path).read_text())
        if not isinstance(records,list) or len(records)>1000:return {}
        secrets=[r['key'].strip() for r in records if isinstance(r,dict) and isinstance(r.get('key'),str)]
        ids=[str(r.get('id','')) for r in records if isinstance(r,dict)]
        if len(ids)!=len(set(ids)):return {}
        by_id={str(r['id']):r for r in records if isinstance(r,dict) and r.get('id') is not None}
        try:_,by_class=pools();config_state='verified'
        except (OSError,ValueError,RuntimeError,PoolUnavailable):by_class={};config_state='unavailable'
        usage={};usage_state='waiting'
        if Path(usage_path).exists():
            try:
                with sqlite3.connect(Path(usage_path).resolve().as_uri()+'?mode=ro',uri=True,timeout=3) as db:
                    db.execute('PRAGMA query_only=ON')
                    if db.execute("SELECT 1 FROM sqlite_master WHERE name='ai_requests' AND type='table'").fetchone():
                        today=now().date();start=(today-timedelta(days=29)).isoformat()
                        for fingerprint,klass,count in db.execute("SELECT key_id,class_name,COUNT(*) FROM ai_requests WHERE class_name IN ('12F','12E') AND day>=? AND day<=? GROUP BY key_id,class_name",(start,today.isoformat())):
                            usage.setdefault(fingerprint,{})[klass]=count
                        usage_state='ready'
            except (sqlite3.Error,OSError):usage_state='unavailable'
        output={}
        for index,status in enumerate(status_records,1):
            if not isinstance(status,dict):continue
            record=by_id.get(str(status.get('id','')))
            if not record or not isinstance(record.get('key'),str) or not record['key'].strip():continue
            fingerprint=hashlib.sha256(record['key'].strip().encode()).hexdigest()[:12]
            observed=usage.get(fingerprint,{})
            output['key-'+str(index)]={'tag':safe_label(record.get('name'),secrets),
                'project':safe_label(record.get('project'),secrets),
                'configured_for':[c for c in ('12F','12E') if fingerprint in by_class.get(c,[])],
                'configuration_state':config_state,'observed_in':[c for c in ('12F','12E') if observed.get(c,0)>0],
                'usage_state':usage_state,'usage_days':30}
        return output
    except (OSError,ValueError,TypeError,KeyError):return {}

def public_metadata(value):
    if not isinstance(value,dict):return None
    if not isinstance(value.get('configured_for'),list) or not isinstance(value.get('observed_in'),list):return None
    if value.get('configuration_state') not in ('verified','unavailable') or value.get('usage_state') not in ('waiting','ready','unavailable') or value.get('usage_days')!=30:return None
    return {'tag':safe_label(value.get('tag')),'project':safe_label(value.get('project')),
        'configured_for':[c for c in ('12F','12E') if c in value.get('configured_for',[])],
        'configuration_state':value['configuration_state'],
        'observed_in':[c for c in ('12F','12E') if c in value.get('observed_in',[])],
        'usage_state':value['usage_state'],'usage_days':30}
