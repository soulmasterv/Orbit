import tempfile,unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock
from orbit_runtime_readers import monitor_snapshot,process_logs
from install_runtime_readers import patched

class RuntimeReadersTests(unittest.TestCase):
    def test_monitor_uses_cached_status_all_keys_and_drops_sensitive_fields(self):
        module=SimpleNamespace(ADMIN_USER="placeholder",ADMIN_PASS="placeholder")
        http=Mock();http.post.return_value.status_code=302;http.get.return_value.status_code=200
        http.get.return_value.json.return_value=[
            {"state":"WORKING","name":"private-sentinel","key":"private-sentinel","auth":{"checked":1793010000},"manual":{"checked":1793010010}}
            for _ in range(12)]
        result=monitor_snapshot(lambda:module,lambda s:"Working",http)
        self.assertEqual(len(result),12);self.assertIn("key-12",result)
        self.assertNotIn("private-sentinel",str(result))
        self.assertIn("2026",result["key-12"]["lastAuthenticationCheck"])
        self.assertFalse(http.post.call_args.kwargs["allow_redirects"])
        self.assertFalse(http.get.call_args.kwargs["allow_redirects"])
        self.assertEqual(http.get.call_count,1)
    def test_monitor_auth_failure_does_not_leak_or_test_keys(self):
        module=SimpleNamespace(ADMIN_USER="private",ADMIN_PASS="private")
        http=Mock();http.post.return_value.status_code=403
        self.assertEqual(monitor_snapshot(lambda:module,lambda s:s,http),{})
        http.get.assert_not_called()
    def test_logs_resolve_current_ids_and_still_restrict_names_paths(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp);log=root/"process.log";log.write_text("Ready\nAuthorization: Bearer private-sentinel\n")
            rows=[{"pm_id":27,"name":"Classera-webhook","pm2_env":{"pm_out_log_path":str(log)}},
                  {"pm_id":9,"name":"Unapproved","pm2_env":{"pm_out_log_path":str(log)}}]
            adapter=process_logs(rows,{"Classera-webhook"},(root,))
            code,payload=adapter.handle("GET","/api/process/27/logs",authenticated=True)
            self.assertEqual(code,200);self.assertNotIn("private-sentinel",str(payload))
            self.assertEqual(adapter.handle("GET","/api/process/9/logs",authenticated=True)[0],404)
            self.assertEqual(adapter.handle("GET","/api/process/27/logs")[0],401)
    def test_replaced_or_external_log_is_never_allowed(self):
        with tempfile.TemporaryDirectory() as temp, tempfile.TemporaryDirectory() as outside:
            log=Path(outside)/"secret";log.write_text("sensitive")
            rows=[{"pm_id":1,"name":"Allowed","pm2_env":{"pm_out_log_path":str(log)}}]
            adapter=process_logs(rows,{"Allowed"},(temp,))
            self.assertEqual(adapter.handle("GET","/api/process/1/logs",authenticated=True)[0],404)
    def test_installer_fails_closed_on_changed_functions(self):
        with self.assertRaises(RuntimeError):patched("def read_gemini():\n    return {}\n")
