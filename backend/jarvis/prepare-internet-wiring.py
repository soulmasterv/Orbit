"""Prepare private staged adapter sources only; never install or restart anything."""
from pathlib import Path
import hashlib,json,subprocess

def once(text, old, new):
    if text.count(old)!=1: raise RuntimeError('Source guard mismatch; inspect wiring before proceeding')
    return text.replace(old,new,1)

def prepare(source, output):
    if output.exists(): raise RuntimeError('Staging destination already exists')
    output.mkdir(mode=0o700)
    originals={name:(source/name).read_text() for name in ['main.mjs','notification-http.mjs','Dockerfile']}
    staged=dict(originals)
    staged['main.mjs']=once(staged['main.mjs'],"import {InternetRequests} from './internet-requests.mjs';", "import {InternetRequests,landline,carrierOf} from './internet-requests.mjs';\nimport {OrbitInternetTracker} from './orbit-internet-tracker.mjs';")
    staged['main.mjs']=once(staged['main.mjs'],"const internetRequests=new InternetRequests('/state',config.owners);", "const internetRequests=new InternetRequests('/state',config.owners);\nconst internetTracker=new OrbitInternetTracker({requests:internetRequests,normalizeLine:landline,normalizeCarrier:carrierOf});")
    staged['main.mjs']=once(staged['main.mjs'],'internetRequests,internetSms,download:', 'internetRequests,internetSms,internetTracker,download:')
    staged['notification-http.mjs']=once(staged['notification-http.mjs'],'allowedCallers,internetRequests,internetSms}){','allowedCallers,internetRequests,internetSms,internetTracker}){')
    auth="if(req.headers.origin||a.length!==b.length||!crypto.timingSafeEqual(a,b))return reply(403,{});"
    staged['notification-http.mjs']=once(staged['notification-http.mjs'],auth,auth+'\n  if(internetTracker && await internetTracker.route(req,reply,res))return;')
    staged['Dockerfile']=once(staged['Dockerfile'],'internet-sms.mjs internet-requests.mjs ', 'orbit-internet-tracker.mjs internet-sms.mjs internet-requests.mjs ')
    receipt={}
    for name,text in staged.items():
        target=output/name;target.write_text(text);target.chmod(0o600)
        if name.endswith('.mjs'):subprocess.run(['node','--check',str(target)],check=True,capture_output=True)
        receipt[name]={'before':hashlib.sha256((source/name).read_bytes()).hexdigest(),'after':hashlib.sha256(target.read_bytes()).hexdigest()}
    (output/'source-guards.json').write_text(json.dumps(receipt,indent=2))
    print(json.dumps({'prepared':list(receipt),'syntax':'passed','installed':False}))

if __name__=='__main__':
    import sys
    prepare(Path(sys.argv[1]),Path(sys.argv[2]))
