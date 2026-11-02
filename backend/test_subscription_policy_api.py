import unittest
import test_classera_students as fixtures
from classera_subscription_policy import install

class SubscriptionPolicyAPITests(unittest.TestCase):
    def setUp(self):
        self.fixture=fixtures.DirectoryTests(methodName='runTest');self.fixture.setUp()
        self.client=self.fixture.client;self.headers=self.fixture.headers;self.url=self.fixture.url;self.directory=self.fixture.directory;self.phone=self.fixture.phone
        with self.directory.connect() as c:install(c)
    def tearDown(self):self.fixture.tearDown()
    def row(self,klass):return {'class_name':klass,'name':'Fixture','status':'active','ai_enabled':1}
    def save(self,rows):
        return self.client.put(self.url,headers=self.headers,json={'expected_revision':self.directory.get(self.phone)['revision'],'subscriptions':rows})
    def policy(self,value,headers=None,revision=None):
        return self.client.put(self.url+'/subscription-policy',headers=self.headers if headers is None else headers,json={'expected_revision':revision or self.directory.get(self.phone)['revision'],'allow_multiple':value})
    def test_default_limit_and_atomic_batch_rejection(self):
        self.assertEqual(self.save([self.row('12F'),self.row('12E')]).status_code,409)
        self.assertEqual(self.directory.get(self.phone)['subscriptions'],[])
        self.assertEqual(self.save([self.row('12F')]).status_code,200)
        response=self.save([self.row('12F'),self.row('12E')])
        self.assertEqual(response.status_code,409);self.assertEqual(response.json['error'],'subscription_limit_reached')
        self.assertEqual(len(self.directory.get(self.phone)['subscriptions']),1)
    def test_override_owner_auth_origin_revision_boolean_and_no_store(self):
        self.assertEqual(self.policy(True,headers={}).status_code,401)
        self.assertEqual(self.policy(True,headers={'X-API-Key':'test-owner'}).status_code,401)
        self.assertEqual(self.policy(True,headers={**self.headers,'Origin':'https://example.com'}).status_code,403)
        self.assertEqual(self.policy(True,revision='0'*64).status_code,409)
        self.assertEqual(self.policy(1).status_code,422)
        before=self.directory.get(self.phone)['revision'];response=self.policy(True)
        self.assertEqual(response.status_code,200);self.assertEqual(response.headers['Cache-Control'],'no-store')
        self.assertNotEqual(response.json['revision'],before);self.assertTrue(response.json['subscription_policy']['allow_multiple'])
    def test_override_and_its_removal_preserve_subscriptions(self):
        self.policy(True);self.assertEqual(self.save([self.row('12F'),self.row('12E')]).status_code,200)
        before=self.directory.get(self.phone)['subscriptions'];response=self.policy(False)
        self.assertTrue(response.json['subscription_policy']['over_limit'])
        self.assertEqual(response.json['subscriptions'],before)
    def test_removal_and_invented_opt_out_denied_without_any_mutation(self):
        self.save([self.row('12F')]);before=self.directory.get(self.phone)
        self.assertEqual(self.save([]).status_code,403)
        self.assertEqual(self.save([{**self.row('12F'),'status':'opted_out'}]).status_code,422)
        self.assertEqual(self.client.delete(self.url,headers=self.headers,json={'expected_revision':before['revision']}).status_code,403)
        self.assertEqual(self.directory.get(self.phone),before)
    def test_disabled_rollout_cannot_claim_enforcement_or_edit_override(self):
        with self.directory.connect() as c:
            c.execute('DROP TRIGGER orbit_classera_single_class_insert')
            c.execute('DROP TRIGGER orbit_classera_single_class_update')
        self.assertFalse(self.directory.get(self.phone)['subscription_policy']['enforced'])
        self.assertEqual(self.policy(True).status_code,503)

if __name__=='__main__':unittest.main()
