import hashlib,json,sqlite3,tempfile,unittest
from pathlib import Path
from datetime import datetime
from zoneinfo import ZoneInfo
from gemini_key_metadata import build_metadata,public_metadata,safe_label

class GeminiMetadataTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.root=Path(self.tmp.name);self.config=self.root/'keys.json';self.db=self.root/'usage.db'
        self.key='AIza'+'x'*35;self.other='AIza'+'y'*35
        self.hash=hashlib.sha256(self.key.encode()).hexdigest()[:12]
        self.records=[{'id':'stable-a','key':self.key,'name':'School primary','project':'School'},{'id':'stable-b','key':self.other,'name':'Personal backup','project':'Home'}]
        self.config.write_text(json.dumps(self.records))
    def tearDown(self):self.tmp.cleanup()
    def read(self,status=None):
        return build_metadata(status or [{'id':'stable-a'},{'id':'stable-b'}],path=self.config,usage_path=self.db,
            pools=lambda:([self.hash],{'12F':[self.hash],'12E':[self.hash]}),now=lambda:datetime(2026,11,2,tzinfo=ZoneInfo('Africa/Cairo')))
    def test_names_projects_and_configured_locations_without_keys_or_hashes(self):
        value=self.read();row=value['key-1']
        self.assertEqual(row['tag'],'School primary');self.assertEqual(row['project'],'School')
        self.assertEqual(row['configured_for'],['12F','12E']);self.assertEqual(row['usage_state'],'waiting')
        for secret in [self.key,self.other,self.hash]:self.assertNotIn(secret,json.dumps(value))
    def test_reordered_status_uses_stable_identity_not_config_position(self):
        value=self.read([{'id':'stable-b'},{'id':'stable-a'}])
        self.assertEqual(value['key-1']['tag'],'Personal backup');self.assertEqual(value['key-2']['configured_for'],['12F','12E'])
    def test_observed_use_is_separate_from_configuration_and_ignores_future_dates(self):
        db=sqlite3.connect(self.db)
        db.execute('CREATE TABLE ai_requests(day TEXT,key_id TEXT,class_name TEXT)')
        db.executemany('INSERT INTO ai_requests VALUES(?,?,?)',[('2026-11-01',self.hash,'12F'),('2026-11-03',self.hash,'12E'),('2026-01-01',self.hash,'12E')])
        db.commit();db.close()
        row=self.read()['key-1'];self.assertEqual(row['usage_state'],'ready');self.assertEqual(row['observed_in'],['12F'])
    def test_secret_or_freeform_content_never_becomes_a_tag(self):
        for text in [self.key,'prefix '+self.key,'Bearer credential','Password: x','line\nbreak','x'*65]:self.assertIsNone(safe_label(text,[self.key]))
        self.records[0]['name']=self.key;self.records[0]['project']=self.other;self.config.write_text(json.dumps(self.records))
        row=self.read()['key-1'];self.assertIsNone(row['tag']);self.assertIsNone(row['project'])
    def test_unmatched_or_duplicate_ids_do_not_get_someone_elses_metadata(self):
        self.assertEqual(self.read([{'id':'missing'}]),{})
        self.records[1]['id']='stable-a';self.config.write_text(json.dumps(self.records));self.assertEqual(self.read(),{})
    def test_public_schema_drops_unknown_fields_and_missing_config_does_not_create_files(self):
        row=self.read()['key-1'];row['key']=self.key
        self.assertNotIn(self.key,json.dumps(public_metadata(row)))
        self.config.unlink();self.assertEqual(self.read(),{});self.assertFalse(self.config.exists());self.assertFalse(self.db.exists())

if __name__=='__main__':unittest.main()
