import sqlite3,unittest
from classera_subscription_hooks import patch_signup,patch_rejoin
from classera_subscription_policy import ERROR,MESSAGE

class SubscriptionHookTests(unittest.TestCase):
    def test_signup_limit_has_no_false_success_or_real_message(self):
        source="def handle_self_service(message, phone_number_id):\n    phone = message['from']\n    name = 'Fixture'\n    class_name = '12E'\n    use_ai = True\n    save_active(phone, name, class_name, use_ai)\n    raise AssertionError('False success after rejected write')\n"
        sent=[]
        def failed(*args):raise sqlite3.IntegrityError(ERROR)
        namespace={'save_active':failed,'send_text':lambda *args:sent.append(args)}
        exec(patch_signup(source),namespace)
        self.assertTrue(namespace['handle_self_service']({'from':'201000000001'},'fixture-number'))
        self.assertEqual(sent,[('201000000001',MESSAGE,'fixture-number')])
    def test_other_database_errors_are_not_hidden(self):
        source="def handle_self_service(message, phone_number_id):\n    phone='201000000001'\n    save_active(phone, 'Fixture', '12E', True)\n"
        def failed(*args):raise sqlite3.OperationalError('Fixture')
        namespace={'save_active':failed};exec(patch_signup(source),namespace)
        with self.assertRaises(sqlite3.OperationalError):namespace['handle_self_service']({},'fixture')
    def test_rejoin_returns_limit_instead_of_false_success(self):
        source='def handle(phone,value):\n    db.execute("UPDATE subscribers SET status=\'active\' WHERE phone=? AND status=\'opted_out\'", (phone,))\n    return "Subscribed again"\n'
        class FixtureDB:
            def execute(self,*args):raise sqlite3.IntegrityError(ERROR)
        namespace={'db':FixtureDB()};exec(patch_rejoin(source),namespace)
        self.assertEqual(namespace['handle']('201000000001','confirm'),MESSAGE)
    def test_unexpected_or_previously_patched_sources_fail_closed(self):
        source="def handle_self_service(message, phone_number_id):\n    save_active('fixture','name','12E',True)\n"
        with self.assertRaises(ValueError):patch_signup(patch_signup(source))
        with self.assertRaises(ValueError):patch_signup('def other(): pass')

if __name__=='__main__':unittest.main()
