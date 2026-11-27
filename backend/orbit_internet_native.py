"""Owner-authenticated facade; reuses existing tracker and vnStat stores."""
import hmac
import http.client
import json
import re
import subprocess
import tempfile
from flask import request, jsonify, send_file
from orbit_jarvis_native import KEY, forward

LIMIT = 50*1024*1024

def traffic_snapshot(run=subprocess.run):
    result = run(['vnstat','--json'],capture_output=True,timeout=8,check=True)
    if len(result.stdout)>2_000_000: raise ValueError('Oversized counters')
    value = json.loads(result.stdout)
    def counter(v):
        if type(v) is not int or v<0: raise ValueError('Invalid counter')
        return v
    def period(row, monthly=False):
        d=row['date']; label=f"{d['year']:04d}-{d['month']:02d}" + ('' if monthly else f"-{d['day']:02d}")
        return dict(date=label,rx=counter(row['rx']),tx=counter(row['tx']))
    interfaces=[]
    for i in value.get('interfaces',[])[:64]:
        name=i['name']; t=i['traffic']
        if not isinstance(name,str) or not re.fullmatch(r'[\w.:-]{1,64}',name):continue
        interfaces.append(dict(id=name,name=i.get('alias') or name,virtual=name.startswith(('veth','docker','br-','tailscale','lo')),updatedAt=i.get('updated',{}).get('timestamp'),rx=counter(t['total']['rx']),tx=counter(t['total']['tx']),days=[period(d) for d in t.get('day',[])[-31:]],months=[period(d,True) for d in t.get('month',[])[-12:]]))
    return dict(version=1,interfaces=interfaces)

def recording_forward(phone,event):
    connection=http.client.HTTPConnection('127.0.0.1',18085,timeout=25); output=None
    try:
        connection.request('GET','/internet/contact/'+phone+'/recordings/'+event,headers={'Authorization':'Bearer '+KEY.read_text().strip()})
        response=connection.getresponse()
        if response.status!=200:return None, response.status if response.status in [404,410] else 503
        output=tempfile.SpooledTemporaryFile(max_size=1024*1024); size=0
        while True:
            data=response.read(65536)
            if not data:break
            size+=len(data)
            if size>LIMIT:raise ValueError('Oversized recording')
            output.write(data)
        if size<44:raise ValueError('Invalid recording')
        output.seek(0); result,output=output,None; return result,200
    finally:
        if output is not None:output.close()
        connection.close()

def register(app,token,transport=forward,audio=recording_forward,traffic=traffic_snapshot):
    def allowed():return bool(token) and not request.headers.get('Origin') and hmac.compare_digest(request.headers.get('Authorization',''),'Bearer '+token)
    def valid(phone):return re.fullmatch(r'[1-9][0-9]{7,14}',phone or '') is not None
    @app.route('/api/jarvis/internet/<phone>',methods=['GET','POST'])
    def internet_contact(phone):
        if not allowed():return jsonify(error='unauthorized'),401
        if not valid(phone) or request.args:return jsonify(error='invalid_contact'),422
        body=None
        if request.method=='POST':
            if not request.is_json or request.content_length is None or request.content_length>4096:return jsonify(error='invalid_request'),422
            body=request.get_json(silent=True)
            if not isinstance(body,dict):return jsonify(error='invalid_request'),422
        try:
            data,status=transport('/internet/contact/'+phone,request.method,body)
            return jsonify(data),status
        except Exception:return jsonify(error='Internet check status unavailable. Refresh before retrying.'),503
    @app.get('/api/jarvis/internet/<phone>/recordings/<event>')
    def internet_audio(phone,event):
        if not allowed():return jsonify(error='unauthorized'),401
        if not valid(phone) or not re.fullmatch(r'[A-F0-9]{8}',event) or request.args:return jsonify(error='recording_not_found'),404
        try:
            data,status=audio(phone,event)
            if status!=200:return jsonify(error='Recording expired' if status==410 else 'Recording unavailable'),status
            response=send_file(data,mimetype='audio/wav',as_attachment=True,download_name=event+'.wav',conditional=False)
            response.call_on_close(data.close);return response
        except Exception:return jsonify(error='Recording unavailable'),503
    @app.get('/api/vnstat')
    def native_vnstat():
        if not allowed():return jsonify(error='unauthorized'),401
        if request.args:return jsonify(error='invalid_request'),422
        try:return jsonify(traffic())
        except Exception:return jsonify(error='Traffic counters unavailable'),503
    @app.after_request
    def internet_private(response):
        if request.path.startswith('/api/jarvis/internet/') or request.path=='/api/vnstat':
            response.headers['Cache-Control']='no-store';response.headers['X-Content-Type-Options']='nosniff'
        return response
