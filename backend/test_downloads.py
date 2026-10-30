import os
import tempfile
import unittest
from pathlib import Path
from flask import Flask
from orbit_downloads import Downloads, register, identifier, parts_for, MAX_BYTES


class DownloadsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name) / 'downloads'
        self.root.mkdir()
        (self.root / '12F').mkdir()
        (self.root / '12F' / 'daily.pdf').write_bytes(b'%PDF-fixture')
        self.reader = Downloads(str(self.root))
        self.app = Flask(__name__)
        register(self.app, 'owner-fixture', self.reader)
        self.client = self.app.test_client()
        self.headers = {'Authorization': 'Bearer owner-fixture'}

    def tearDown(self):
        self.temp.cleanup()

    def test_authenticated_listing_nested_file_and_no_store(self):
        response = self.client.get('/api/downloads', headers=self.headers)
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.headers['Cache-Control'], 'no-store')
        folder = response.json['items'][0]
        self.assertEqual(folder['kind'], 'folder')
        response = self.client.get('/api/downloads?folder=' + folder['id'], headers=self.headers)
        file = response.json['items'][0]
        self.assertEqual(file['name'], 'daily.pdf')
        response = self.client.get('/api/downloads/files/' + file['id'], headers=self.headers)
        self.assertEqual(response.data, b'%PDF-fixture')
        self.assertEqual(response.headers['Cache-Control'], 'no-store')
        self.assertEqual(response.headers['X-Content-Type-Options'], 'nosniff')

    def test_missing_wrong_auth_and_browser_origin(self):
        for headers in [{}, {'Authorization': 'Bearer wrong'}]:
            self.assertEqual(self.client.get('/api/downloads', headers=headers).status_code, 401)
        self.assertEqual(self.client.get('/api/downloads', headers={**self.headers, 'Origin': 'https://example.test'}).status_code, 403)

    def test_traversal_hidden_absolute_and_invalid_ids(self):
        for raw in ['../outside', '/etc/passwd', '.env', '12F/../../outside', '12F\\secret', '12F//daily.pdf']:
            with self.assertRaises(ValueError):
                parts_for(identifier(raw.split('/')))
        for value in ['!', 'a' * 4097, '%2e%2e']:
            self.assertEqual(self.client.get('/api/downloads?folder=' + value, headers=self.headers).status_code, 422)

    def test_symlinks_and_special_files_not_listed_or_read(self):
        outside = Path(self.temp.name) / 'secret'
        outside.write_bytes(b'private')
        os.symlink(outside, self.root / 'linked.pdf')
        os.symlink(Path(self.temp.name), self.root / 'escape')
        os.mkfifo(self.root / 'pipe')
        self.assertEqual([r['name'] for r in self.reader.listing()['items']], ['12F'])
        for path in [['linked.pdf'], ['escape', 'secret'], ['pipe']]:
            with self.assertRaises((OSError, ValueError)):
                self.reader.read(identifier(path))

    def test_missing_root_removed_file_and_oversized_file(self):
        self.assertEqual(self.client.get('/api/downloads/files/' + identifier(['missing.pdf']), headers=self.headers).status_code, 404)
        with (self.root / 'large.pdf').open('wb') as stream:
            stream.truncate(MAX_BYTES + 1)
        self.assertEqual(self.client.get('/api/downloads/files/' + identifier(['large.pdf']), headers=self.headers).status_code, 413)
        self.assertFalse((self.root / 'missing.pdf').exists())

    def test_mutations_are_unavailable_and_files_unchanged(self):
        before = (self.root / '12F' / 'daily.pdf').read_bytes()
        for method in ['post', 'put', 'delete']:
            self.assertEqual(getattr(self.client, method)('/api/downloads', headers=self.headers).status_code, 405)
        self.assertEqual((self.root / '12F' / 'daily.pdf').read_bytes(), before)


if __name__ == '__main__':
    unittest.main()
