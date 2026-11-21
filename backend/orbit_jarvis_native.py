"""Native owner-only bridge. Pairing and WhatsApp secrets never leave Ubuntu."""
import hmac
import json
import re
from pathlib import Path
import urllib.request
import urllib.error
from flask import request, jsonify

KEY = Path.home() / 'jarvis/whatsapp-secrets/gateway.key'

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None

def forward(path, method, body=None):
    key = KEY.read_text().strip()
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request('http://127.0.0.1:18085' + path, data=data, method=method,
        headers={'Authorization': 'Bearer ' + key, 'Content-Type': 'application/json'})
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    try:
        with opener.open(req, timeout=18) as result:
            data = result.read(2_000_001)
            if len(data) > 2_000_000:
                raise ValueError('Response too large')
            return json.loads(data), result.status
    except urllib.error.HTTPError as error:
        return {'error': 'WhatsApp request unavailable. Refresh status before retrying.'}, error.code if error.code in (400, 401, 403, 404, 409, 413, 429, 503) else 502

def register(app, token, transport=forward):
    def allowed():
        return not request.headers.get('Origin') and hmac.compare_digest(request.headers.get('Authorization', ''), 'Bearer ' + token)
    def handle(path):
        if not allowed():
            return jsonify(error='unauthorized'), 401
        if request.method == 'POST':
            if request.content_length is None or request.content_length > 60000 or not request.is_json:
                return jsonify(error='invalid_request'), 400
            body = request.get_json(silent=True)
            if not isinstance(body, dict):
                return jsonify(error='invalid_request'), 400
        else:
            body = None
        try:
            value, status = transport(path, request.method, body)
            response = jsonify(value)
            response.headers['Cache-Control'] = 'no-store'
            return response, status
        except Exception:
            return jsonify(error='WhatsApp unavailable. A send may be unconfirmed; refresh status before retrying.'), 503
    @app.route('/api/jarvis/whatsapp', methods=['GET'])
    def native_whatsapp_chats():
        return handle('/inbox')
    @app.route('/api/jarvis/whatsapp/chats/<phone>', methods=['GET'])
    def native_whatsapp_messages(phone):
        if not phone.isascii() or not phone.isdecimal() or not 8 <= len(phone) <= 15:
            return jsonify(error='invalid_recipient'), 400
        before = request.args.get('before')
        if before and not re.fullmatch(r'[A-Za-z0-9_-]{1,160}', before):
            return jsonify(error='invalid_cursor'), 400
        return handle('/inbox/' + phone + ('?before=' + before if before else ''))
    @app.route('/api/jarvis/whatsapp/send', methods=['POST'])
    def native_whatsapp_send():
        return handle('/inbox/send')
    @app.route('/api/jarvis/whatsapp/read', methods=['POST'])
    def native_whatsapp_read():
        return handle('/inbox/read')
    @app.route('/api/jarvis/whatsapp/requests/<uuid:identifier>', methods=['GET'])
    def native_whatsapp_request(identifier):
        return handle('/inbox/requests/' + str(identifier))
    @app.route('/api/jarvis/fun-call', methods=['POST'])
    def native_fun_call():
        return handle('/fun-call')
