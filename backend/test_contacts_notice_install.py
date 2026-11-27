import ast
import sys
import types
import unittest
from unittest.mock import patch
from install_contacts_notice_refresh import patch_ai_notice_hook, patch_phone_history


class ContactsInstallTests(unittest.TestCase):
    def test_history_patch_preserves_auth_and_only_replaces_history_body(self):
        source = '''def register():
    @auth
    def diaa_history():
        return legacy_history()
    def untouched():
        return "same"
'''
        result = patch_phone_history(source)
        tree = ast.parse(result); route = next(n for n in ast.walk(tree) if isinstance(n, ast.FunctionDef) and n.name == 'diaa_history')
        self.assertEqual(ast.unparse(route.decorator_list[0]), 'auth')
        self.assertIn('orbit_call_history', result); self.assertIn('return "same"', result)
        self.assertNotIn('legacy_history', result)
        with self.assertRaises(ValueError): patch_phone_history(result)

    def test_ai_hook_runs_only_after_success_and_does_not_interrupt_ai_followup(self):
        source = '''def handle_ai_button(message, phone_number_id):
    report_class = "12F"
    ai_sent = message["fixture_sent"]
    if ai_sent:
        followup()
'''
        result = patch_ai_notice_hook(source); observed = []; followups = []
        module = types.ModuleType('classera_report_notices'); module.after_ai_request = lambda m, c: observed.append(c)
        scope = {'followup': lambda: followups.append(True)}
        with patch.dict(sys.modules, {'classera_report_notices': module}):
            exec(result, scope)
            scope['handle_ai_button']({'fixture_sent': False}, 'fixture'); self.assertEqual(observed, [])
            scope['handle_ai_button']({'fixture_sent': True}, 'fixture'); self.assertEqual(observed, ['12F'])
            module.after_ai_request = lambda *a: (_ for _ in ()).throw(RuntimeError('fixture failure'))
            scope['handle_ai_button']({'fixture_sent': True}, 'fixture'); self.assertEqual(len(followups), 2)
        with self.assertRaises(ValueError): patch_ai_notice_hook(result)
