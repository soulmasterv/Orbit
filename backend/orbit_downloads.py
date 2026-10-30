"""Read-only, owner-authenticated Classera downloads. No bot/provider calls."""
import base64
import hmac
import io
import mimetypes
import os
import re
import stat
from flask import jsonify, request, send_file

ROOT = '/home/local/classera/downloads'
MAX_BYTES = 25 * 1024 * 1024


def identifier(parts):
    return base64.urlsafe_b64encode('/'.join(parts).encode()).decode().rstrip('=')


def parts_for(value):
    if not isinstance(value, str) or not re.fullmatch(r'[A-Za-z0-9_-]{1,4096}', value):
        raise ValueError()
    raw = base64.b64decode(value + '=' * (-len(value) % 4), altchars=b'-_', validate=True).decode()
    parts = raw.split('/')
    if any(not p or p.startswith('.') or '\\' in p or '\x00' in p for p in parts):
        raise ValueError()
    if identifier(parts) != value:
        raise ValueError()
    return parts


class Downloads:
    def __init__(self, root=ROOT):
        self.root = root

    def open(self, parts, folder=False):
        # Every component is opened relative to a pinned directory descriptor.
        # NOFOLLOW prevents symlink swaps from escaping the allowed root.
        fd = os.open(self.root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            for index, part in enumerate(parts):
                flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK
                if index < len(parts) - 1 or folder:
                    flags |= os.O_DIRECTORY
                child = os.open(part, flags, dir_fd=fd)
                os.close(fd)
                fd = child
            return fd
        except BaseException:
            os.close(fd)
            raise

    def listing(self, folder=None, cursor=None):
        parts = parts_for(folder) if folder else []
        if cursor is not None and not re.fullmatch(r'[0-9]{1,6}', cursor):
            raise ValueError()
        offset = int(cursor or 0)
        fd = self.open(parts, folder=True)
        rows = []
        try:
            with os.scandir(fd) as entries:
                for entry in entries:
                    if entry.name.startswith('.') or '\\' in entry.name:
                        continue
                    info = entry.stat(follow_symlinks=False)
                    if not (stat.S_ISDIR(info.st_mode) or stat.S_ISREG(info.st_mode)):
                        continue
                    if len(rows) == 50000:
                        raise OSError('Folder listing limit exceeded')
                    rows.append(dict(id=identifier(parts + [entry.name]), name=entry.name,
                                     kind='folder' if stat.S_ISDIR(info.st_mode) else 'file',
                                     size=info.st_size, modified_at=int(info.st_mtime)))
        finally:
            os.close(fd)
        rows.sort(key=lambda r: (r['kind'] != 'folder', -r['modified_at'], r['name']))
        page = rows[offset:offset + 1000]
        more = offset + len(page) < len(rows)
        return dict(version=1, items=page, truncated=more,
                    next_cursor=str(offset + len(page)) if more else None)

    def read(self, value):
        parts = parts_for(value)
        fd = self.open(parts)
        with os.fdopen(fd, 'rb') as stream:
            info = os.fstat(stream.fileno())
            if not stat.S_ISREG(info.st_mode):
                raise ValueError()
            if info.st_size > MAX_BYTES:
                raise OverflowError()
            data = stream.read(MAX_BYTES + 1)
            if len(data) > MAX_BYTES:
                raise OverflowError()
        return data, parts[-1]


def register(app, owner_token, downloads=None):
    downloads = downloads or Downloads()

    def handle(file_id=None):
        supplied = request.headers.get('Authorization', '')
        if not owner_token or not hmac.compare_digest(supplied.encode(), ('Bearer ' + owner_token).encode()):
            return jsonify(error='unauthorized'), 401
        if request.headers.get('Origin') or request.headers.get('Sec-Fetch-Site') == 'cross-site':
            return jsonify(error='owner_not_permitted'), 403
        try:
            if file_id is None:
                if set(request.args) - {'folder', 'cursor'}:
                    raise ValueError()
                return jsonify(downloads.listing(request.args.get('folder'), request.args.get('cursor')))
            data, name = downloads.read(file_id)
            response = send_file(io.BytesIO(data), mimetype=mimetypes.guess_type(name)[0] or 'application/octet-stream',
                                 as_attachment=True, download_name=name, max_age=0)
            response.headers['X-Content-Type-Options'] = 'nosniff'
            return response
        except (ValueError, UnicodeError):
            return jsonify(error='invalid_identifier'), 422
        except FileNotFoundError:
            return jsonify(error='not_found'), 404
        except OverflowError:
            return jsonify(error='file_too_large'), 413
        except OSError:
            return jsonify(error='downloads_unavailable'), 503

    app.add_url_rule('/api/downloads', 'orbit_downloads_list', handle, methods=['GET'])
    app.add_url_rule('/api/downloads/files/<file_id>', 'orbit_downloads_file', handle, methods=['GET'])

    @app.after_request
    def private_downloads(response):
        if request.path.startswith('/api/downloads'):
            response.headers['Cache-Control'] = 'no-store'
        return response
