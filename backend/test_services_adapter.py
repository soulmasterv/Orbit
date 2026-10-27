import json
import unittest
from services_adapter import ServicesAdapter

class AdapterTests(unittest.TestCase):
    def test_authentication_and_missing_provider_fail_closed(self):
        adapter = ServicesAdapter()
        self.assertEqual(adapter.handle("GET", "/api/services")[0], 401)
        self.assertEqual(adapter.handle("GET", "/api/services", authenticated=True)[0], 501)

    def test_only_allowlisted_actions_and_deduplication(self):
        calls = []
        adapter = ServicesAdapter(classera_fires={"classera-1": lambda: calls.append(1), "arbitrary": lambda: calls.append(2)})
        self.assertEqual(adapter.handle("POST", "/api/services/classera/classera-1/fire")[0], 401)
        self.assertEqual(adapter.handle("POST", "/api/services/classera/arbitrary/fire", authenticated=True)[0], 404)
        self.assertEqual(adapter.handle("POST", "/api/services/classera/classera-1/fire", authenticated=True)[0], 200)
        self.assertEqual(adapter.handle("POST", "/api/services/classera/classera-1/fire", authenticated=True)[0], 409)
        self.assertEqual(calls, [1])

    def test_secrets_and_arbitrary_status_text_are_removed(self):
        unsafe = {"geminiHealth": "secret-sentinel", "gemini": {"key-1": {"status": "secret-sentinel", "name": "secret-sentinel", "apiKey": "secret-sentinel"}},
                  "padel": {"whatsapp": {"status": "online", "deliveryStatus": "billing required"}}}
        adapter = ServicesAdapter(reader=lambda: unsafe)
        status, result = adapter.handle("GET", "/api/services", authenticated=True)
        self.assertEqual(status, 200)
        self.assertNotIn("secret-sentinel", json.dumps(result))
        self.assertEqual(len(result["gemini"]), 1)
        self.assertEqual(len(result["classera"]), 3)
        self.assertEqual(result["padel"][-1]["status"], "Online")
        self.assertEqual(result["padel"][-1]["deliveryStatus"], "Billing Required")

    def test_upstream_failure_does_not_leak_exception(self):
        def fail(): raise RuntimeError("secret-sentinel")
        adapter = ServicesAdapter(reader=fail)
        self.assertEqual(adapter.handle("GET", "/api/services", authenticated=True), (503, {"ok": False}))

if __name__ == "__main__": unittest.main()

class DynamicKeysTests(unittest.TestCase):
    def test_all_configured_keys_and_only_registered_tests(self):
        raw={"gemini":{f"key-{i}":{"status":"Working","apiKey":"private-sentinel","name":"private-sentinel"} for i in range(1,13)}}
        raw["gemini"]["../unsafe"]={"status":"Working"}
        calls=[]
        adapter=ServicesAdapter(reader=lambda:raw,gemini_tests={"key-12":lambda:calls.append(12),"key-9999":lambda:calls.append(9999)})
        code,data=adapter.handle("GET","/api/services",authenticated=True)
        self.assertEqual(code,200);self.assertEqual(len(data["gemini"]),12)
        self.assertEqual(data["gemini"][-1]["name"],"Gemini 12")
        self.assertNotIn("private-sentinel",json.dumps(data))
        self.assertEqual(adapter.handle("POST","/api/services/gemini/key-12/test",authenticated=True)[0],200)
        self.assertEqual(adapter.handle("POST","/api/services/gemini/key-13/test",authenticated=True)[0],404)
        self.assertEqual(calls,[12])
    def test_empty_monitor_does_not_invent_ten_keys(self):
        result=ServicesAdapter(reader=lambda:{"gemini":{}}).handle("GET","/api/services",authenticated=True)[1]
        self.assertEqual(result["gemini"],[])
