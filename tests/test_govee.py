"""Run: python3 -I tests/test_govee.py"""
import importlib.util, json, os, subprocess, sys, tempfile, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "..", "govee.py")
spec = importlib.util.spec_from_file_location("govee", SCRIPT)
govee = importlib.util.module_from_spec(spec)
spec.loader.exec_module(govee)


class Sanitize(unittest.TestCase):
    def test_rejects_unsafe_ids(self):
        self.assertIsNone(govee.sanitize_device({"sku": "H6008", "device": "a; rm -rf /"}))
        self.assertIsNone(govee.sanitize_device({"sku": "../x", "device": "AA"}))

    def test_clips_names_and_drops_bad_caps(self):
        dev = govee.sanitize_device({
            "sku": "H6008", "device": "AA:BB", "deviceName": "<img src=x>" + "a" * 500,
            "type": "devices.types.light",
            "capabilities": [
                {"type": "devices.capabilities.on_off", "instance": "powerSwitch"},
                {"type": "evil", "instance": "x"},
                {"type": "devices.capabilities.range", "instance": "bad instance!"},
            ],
        })
        self.assertEqual(dev["type"], "light")
        self.assertLessEqual(len(dev["name"]), 80)
        self.assertEqual([c["instance"] for c in dev["capabilities"]], ["powerSwitch"])

    def test_nested_work_mode_options(self):
        opts = govee.sanitize_options([{"name": "gearMode", "options": [{"name": "Low", "value": 1}]}, {"name": "Fan", "defaultValue": 0}])
        self.assertEqual(opts[0]["options"][0]["value"], 1)
        self.assertEqual(opts[1]["defaultValue"], 0)


class Cli(unittest.TestCase):
    def run_cli(self, *args, stdin="", env=None):
        e = dict(os.environ, XDG_CONFIG_HOME=self.tmp, GOVEE_API_KEY="")
        e.update(env or {})
        p = subprocess.run([sys.executable, "-I", SCRIPT, *args], input=stdin, capture_output=True, text=True, env=e, timeout=30)
        return json.loads(p.stdout)

    def setUp(self):
        self.tmp = tempfile.mkdtemp()

    def test_status_without_key(self):
        self.assertEqual(self.run_cli("status"), {"ok": True, "configured": False})

    def test_devices_without_key_needs_key(self):
        r = self.run_cli("devices")
        self.assertFalse(r["ok"]); self.assertTrue(r["needsKey"])

    def test_set_key_rejects_garbage_without_network(self):
        r = self.run_cli("set-key", stdin="not a key!\n")
        self.assertFalse(r["ok"])

    def test_control_validates_args(self):
        r = self.run_cli("control", "H6008", "AA;BB", "devices.capabilities.on_off", "powerSwitch", "1")
        self.assertEqual(r["error"], "Invalid device id")
        r = self.run_cli("control", "H6008", "AA:BB", "devices.capabilities.on_off", "powerSwitch", "{bad")
        self.assertEqual(r["error"], "Value is not JSON")

    def test_saved_key_is_private(self):
        govee.CONFIG_DIR = os.path.join(self.tmp, "omarchy", "govee")
        govee.CONFIG_FILE = os.path.join(govee.CONFIG_DIR, "config.json")
        govee.save_key("abc-123")
        self.assertEqual(os.stat(govee.CONFIG_FILE).st_mode & 0o777, 0o600)
        self.assertEqual(self.run_cli("status"), {"ok": True, "configured": True})
        self.assertEqual(self.run_cli("clear-key"), {"ok": True})
        self.assertFalse(os.path.exists(govee.CONFIG_FILE))


    def test_hide_and_unhide(self):
        self.assertEqual(self.run_cli("hide", "AA:BB"), {"ok": True, "device": "AA:BB", "hidden": True})
        self.run_cli("hide", "CC:DD")
        self.run_cli("hide", "AA:BB")
        path = os.path.join(self.tmp, "omarchy", "govee", "hidden.json")
        with open(path) as fh:
            self.assertEqual(json.load(fh), {"hidden": ["CC:DD", "AA:BB"]})
        self.assertEqual(os.stat(path).st_mode & 0o777, 0o600)
        self.run_cli("unhide", "AA:BB")
        with open(path) as fh:
            self.assertEqual(json.load(fh), {"hidden": ["CC:DD"]})
        self.assertFalse(self.run_cli("hide", "bad id;")["ok"])

    def test_forgetting_key_keeps_hidden_devices(self):
        self.run_cli("hide", "AA:BB")
        self.run_cli("clear-key")
        self.assertTrue(os.path.exists(os.path.join(self.tmp, "omarchy", "govee", "hidden.json")))


    def test_set_order_and_apply(self):
        self.assertEqual(self.run_cli("set-order", "B", "A", "B"), {"ok": True, "count": 2})
        self.assertFalse(self.run_cli("set-order", "ok", "bad;id")["ok"])
        self.assertFalse(self.run_cli("set-order")["ok"])
        devs = [{"device": d} for d in ["A", "B", "C", "D"]]
        ordered = govee.apply_order(devs, ["C", "A"])
        self.assertEqual([d["device"] for d in ordered], ["C", "A", "B", "D"])


if __name__ == "__main__":
    unittest.main()
