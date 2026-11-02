import unittest
import test_classera_students as fixtures
from classera_students import removable_profile

class OptOutRemovalTests(unittest.TestCase):
    def setUp(self):
        self.f=fixtures.DirectoryTests(methodName='runTest');self.f.setUp()
        self.directory=self.f.directory;self.phone=self.f.phone
    def tearDown(self):self.f.tearDown()
    def seed(self,status='opted_out',klass='12F'):
        with self.directory.connect() as c:
            c.execute('INSERT INTO subscribers VALUES(?,?,?,?,?,?,?)',(self.phone,'Fixture',klass,1,status,'before','before'))
    def delete(self,revision=None,headers=None):
        return self.f.client.delete(self.f.url,headers=self.f.headers if headers is None else headers,json={'expected_revision':revision or self.directory.get(self.phone)['revision']})
    def test_only_all_opted_out_can_be_removed_and_auth_is_required(self):
        self.seed();self.seed(klass='12E')
        self.assertEqual(self.delete(headers={}).status_code,401)
        self.assertEqual(self.delete().status_code,200)
        self.assertEqual(self.directory.get(self.phone)['subscriptions'],[])
        self.assertEqual(self.directory.listing()['students'],[])
    def test_mixed_active_paused_waiting_and_unknown_never_removed(self):
        for status in ['active','paused','waiting_for_class','unknown']:
            with self.directory.connect() as c:c.execute('DELETE FROM subscribers')
            self.seed();self.seed(status,klass='LEGACY')
            before=self.directory.get(self.phone)
            self.assertEqual(self.delete().status_code,403)
            self.assertEqual(self.directory.get(self.phone),before)
    def test_stale_revision_and_reactivation_race_cannot_delete(self):
        self.seed();revision=self.directory.get(self.phone)['revision']
        with self.directory.connect() as c:c.execute("UPDATE subscribers SET name='Changed'")
        self.assertEqual(self.delete(revision).status_code,409)
        with self.directory.connect() as c:c.execute("UPDATE subscribers SET status='active'")
        self.assertEqual(self.delete(revision).status_code,403)
        self.assertEqual(len(self.directory.get(self.phone)['subscriptions']),1)
    def test_signup_in_progress_and_empty_profile_are_not_opt_out_proof(self):
        self.assertFalse(removable_profile(self.directory.get(self.phone)))
        self.seed()
        with self.directory.connect() as c:c.execute('INSERT INTO signup_sessions VALUES(?,?,?,?,?)',(self.phone,'class','Fixture','12E','before'))
        self.assertEqual(self.delete().status_code,403)
    def test_admin_restriction_is_preserved_without_a_ghost_directory_entry(self):
        self.seed()
        with self.directory.connect() as c:
            c.execute('INSERT INTO orbit_student_controls VALUES(?,?,?)',(self.phone,'suspended','before'))
            c.execute('INSERT INTO orbit_classera_subscription_policy VALUES(?,?,?)',(self.phone,1,'before'))
        self.assertEqual(self.delete().status_code,200)
        self.assertEqual(self.directory.get(self.phone)['activity_status'],'suspended')
        self.assertEqual(self.directory.listing()['students'],[])
        recreated=self.directory.create({'phone':self.phone,'name':'Recreated fixture'})
        self.assertEqual(recreated['activity_status'],'suspended')
        self.assertFalse(recreated['subscription_policy']['allow_multiple'])

if __name__=='__main__':unittest.main()
