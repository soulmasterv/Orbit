"""Native owner-only bridge. Pairing and WhatsApp secrets never leave Ubuntu."""
import hmac
import base64
import json
import re
import http.client
import tempfile
from urllib.parse import urlencode
from pathlib import Path
import urllib.request
import urllib.error
from flask import request, jsonify, send_file

KEY = Path.home() / 'jarvis/whatsapp-secrets/gateway.key'
MEDIA_LIMIT = 25 * 1024 * 1024

def media_forward(identifier, method, query, stream=None, length=None):
    connection = http.client.HTTPConnection('127.0.0.1', 18085, timeout=60)
    output = None
    try:
        path = '/inbox/media/' + identifier
        if method == 'PUT':
            path += '?' + urlencode({key:value for key,value in query.items() if key != 'thumbnail'})
            connection.putrequest('PUT', path)
            connection.putheader('Authorization', 'Bearer ' + KEY.read_text().strip())
            connection.putheader('Content-Type', 'application/octet-stream')
            connection.putheader('Content-Length', str(length))
            if query.get('thumbnail'):
                connection.putheader('X-Orbit-Thumbnail', query['thumbnail'])
            connection.endheaders()
            remaining = length
            while remaining:
                chunk = stream.read(min(65536, remaining))
                if not chunk:
                    raise ValueError('Incomplete attachment')
                connection.send(chunk)
                remaining -= len(chunk)
        else:
            connection.request('GET', path, headers={'Authorization': 'Bearer ' + KEY.read_text().strip()})
        response = connection.getresponse()
        if response.status != 200:
            return {'error': 'Attachment unavailable. Check the format and 25 MB limit.'}, 400
        if method == 'PUT':
            return json.loads(response.read(20001)), 200
        output = tempfile.SpooledTemporaryFile(max_size=1024*1024)
        size = 0
        while True:
            chunk = response.read(65536)
            if not chunk:
                break
            size += len(chunk)
            if size > MEDIA_LIMIT:
                raise ValueError('Attachment too large')
            output.write(chunk)
        output.seek(0)
        result, output = output, None
        return result, 200
    finally:
        if output is not None:
            output.close()
        connection.close()

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
        with opener.open(req, timeout=85 if path == '/inbox/send' and isinstance(body, dict) and body.get('media_id') else 18) as result:
            data = result.read(2_000_001)
            if len(data) > 2_000_000:
                raise ValueError('Response too large')
            return json.loads(data), result.status
    except urllib.error.HTTPError as error:
        return {'error': 'WhatsApp request unavailable. Refresh status before retrying.'}, error.code if error.code in (400, 401, 403, 404, 409, 413, 429, 503) else 502

def register(app, token, transport=forward, media_transport=media_forward):
    from orbit_internet_native import register as register_internet
    register_internet(app, token, transport=transport)
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
    @app.route('/api/jarvis/allowed-callers', methods=['GET', 'POST'])
    def native_allowed_callers():
        return handle('/allowed-callers')
    @app.route('/api/jarvis/fun-call', methods=['POST'])
    def native_fun_call():
        return handle('/fun-call')
    @app.route('/api/jarvis/whatsapp/media/<uuid:identifier>', methods=['GET', 'PUT'])
    def native_whatsapp_media(identifier):
        if not allowed():
            return jsonify(error='unauthorized'), 401
        query = {}
        if request.method == 'PUT':
            if not request.content_length or request.content_length > MEDIA_LIMIT:
                return jsonify(error='Attachment exceeds 25 MB'), 413
            query = {key: request.args.get(key, '') for key in ('kind', 'mime')}
            try:
                encoded = request.headers.get('X-Orbit-File-Name', '')
                if len(encoded) > 800:
                    raise ValueError('Name too long')
                query['name'] = base64.b64decode(encoded, validate=True).decode('utf-8')
            except Exception:
                return jsonify(error='invalid_attachment'), 400
            thumbnail = request.headers.get('X-Orbit-Thumbnail', '')
            if thumbnail:
                try:
                    if len(thumbnail) > 5500 or len(base64.b64decode(thumbnail, validate=True)) > 4000:
                        raise ValueError('Thumbnail too large')
                    query['thumbnail'] = thumbnail
                except Exception:
                    return jsonify(error='invalid_attachment'), 400
            if query['kind'] not in ('image', 'video', 'document') or not 1 <= len(query['name']) <= 120 or not re.fullmatch(r'[A-Za-z0-9!#$&^_.+-]+/[A-Za-z0-9!#$&^_.+-]{1,80}', query['mime']):
                return jsonify(error='invalid_attachment'), 400
        try:
            payload, status = media_transport(str(identifier), request.method, query, request.stream, request.content_length)
            if isinstance(payload, dict):
                result = jsonify(payload)
            else:
                result = send_file(payload, mimetype='application/octet-stream', as_attachment=True, download_name='attachment', max_age=0)
                result.call_on_close(payload.close)
            result.headers['Cache-Control'] = 'no-store'
            result.headers['X-Content-Type-Options'] = 'nosniff'
            return result, status
        except Exception:
            return jsonify(error='Attachment transfer failed. No message was submitted by this transfer.'), 503
