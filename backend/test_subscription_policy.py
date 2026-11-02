import sqlite3,tempfile,threading,unittest
from contextlib import closing
from pathlib import Path
from classera_subscription_policy import install,read,set_override,is_limit_error

class SubscriptionPolicyTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.path=Path(self.tmp.name)/'fixture.db'
        self.db=sqlite3.connect(self.path)
        self.db.execute('CREATE TABLE subscribers(phone TEXT,class_name TEXT,status TEXT,ai_enabled INTEGER,PRIMARY KEY(phone,class_name))')
        install(self.db);self.db.commit()
    def tearDown(self):
        self.db.close();self.tmp.cleanup()
    def insert(self,klass,status='active',phone='201000000001'):
        self.db.execute('INSERT INTO subscribers VALUES(?,?,?,1)',(phone,klass,status))
    def test_second_class_rejected_with_active_or_paused_first(self):
        for state in ('active','paused'):
            self.db.execute('DELETE FROM subscribers');self.insert('12F',state)
            with self.assertRaises(sqlite3.IntegrityError) as error:self.insert('12E')
            self.assertTrue(is_limit_error(error.exception))
            self.assertEqual(read(self.db,'201000000001')['occupied_classes'],1)
    def test_opt_out_and_waiting_do_not_occupy_slot(self):
        self.insert('12F','opted_out');self.insert('12D','waiting_for_class');self.insert('12E')
        self.assertEqual(read(self.db,'201000000001')['occupied_classes'],1)
    def test_rejoin_cannot_bypass_limit(self):
        self.insert('12F','opted_out');self.insert('12E')
        with self.assertRaises(sqlite3.IntegrityError):
            self.db.execute("UPDATE subscribers SET status='active' WHERE class_name='12F'")
        self.assertEqual(self.db.execute("SELECT status FROM subscribers WHERE class_name='12F'").fetchone()[0],'opted_out')
    def test_override_applies_only_to_selected_phone(self):
        set_override(self.db,'201000000001',True,'fixture');self.insert('12F');self.insert('12E')
        self.insert('12F',phone='201000000002')
        with self.assertRaises(sqlite3.IntegrityError):self.insert('12E',phone='201000000002')
        self.assertTrue(read(self.db,'201000000001')['allow_multiple'])
    def test_removing_override_preserves_existing_rows_and_allows_existing_edits(self):
        set_override(self.db,'201000000001',True,'before');self.insert('12F');self.insert('12E')
        set_override(self.db,'201000000001',False,'after')
        self.assertTrue(read(self.db,'201000000001')['over_limit'])
        self.db.execute("UPDATE subscribers SET ai_enabled=0,status='paused' WHERE class_name='12F'")
        self.assertEqual(self.db.execute('SELECT COUNT(*) FROM subscribers').fetchone()[0],2)
        with self.assertRaises(sqlite3.IntegrityError):self.insert('12D')
    def test_existing_upsert_and_class_change_do_not_add_a_slot(self):
        self.insert('12F')
        self.db.execute("INSERT INTO subscribers VALUES('201000000001','12F','active',0) ON CONFLICT(phone,class_name) DO UPDATE SET ai_enabled=0,status='active'")
        self.db.execute("UPDATE subscribers SET class_name='12E' WHERE class_name='12F'")
        self.assertEqual(read(self.db,'201000000001')['occupied_classes'],1)
    def test_install_is_additive_and_idempotent(self):
        set_override(self.db,'201000000001',True,'fixture');self.insert('12F');self.insert('12E')
        before=self.db.execute('SELECT * FROM subscribers ORDER BY class_name').fetchall()
        install(self.db)
        self.assertEqual(before,self.db.execute('SELECT * FROM subscribers ORDER BY class_name').fetchall())
    def test_override_requires_real_boolean(self):
        for value in (1,0,None,'true',[]):
            with self.assertRaises(ValueError):set_override(self.db,'201000000001',value,'fixture')
    def test_concurrent_writers_cannot_create_two_classes(self):
        self.db.commit();barrier=threading.Barrier(2);results=[]
        def writer(klass):
            with closing(sqlite3.connect(self.path,timeout=5)) as c, c:
                barrier.wait()
                try:
                    c.execute('INSERT INTO subscribers VALUES(?,?,?,1)',('201000000001',klass,'active'))
                    results.append('saved')
                except sqlite3.IntegrityError as error:
                    results.append('limited' if is_limit_error(error) else 'unexpected')
        threads=[threading.Thread(target=writer,args=(k,)) for k in ('12E','12F')]
        for t in threads:t.start()
        for t in threads:t.join()
        self.assertEqual(sorted(results),['limited','saved'])
        self.assertEqual(read(self.db,'201000000001')['occupied_classes'],1)

if __name__=='__main__':unittest.main()
