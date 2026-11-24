"""Tests for phone-adb-run and phone-adb-grant with a fake adb. Run: python3 -m unittest -v (in this folder)."""
import io
import json
import os
import stat
import subprocess
import sys
import tempfile
import time
import types
import unittest
from contextlib import redirect_stdout

HERE = os.path.dirname(os.path.abspath(__file__))


def load(name, **subst):
    src = open(os.path.join(HERE, name)).read()
    for k, v in subst.items():
        src = src.replace(k, v)
    mod = types.ModuleType(name)
    mod.__dict__["__name__"] = "test_" + name
    exec(compile(src, name, "exec"), mod.__dict__)
    return mod


FAKE_ADB = """#!/bin/sh
# fake adb: -L/-s are accepted and ignored
while [ "$1" = "-s" ]; do shift 2; done
case "$1" in
  devices) printf 'List of devices attached\\n192.168.1.50:37000\\tdevice\\n';;
  connect) echo "connected to $2";;
  pair) if [ "$3" = "123456" ]; then echo "Successfully paired to $2"; else echo "Failed: wrong code"; fi;;
  shell) shift; echo "ran: $*"; exit 3;;
  exec-out) shift; case "$1" in screencap) printf '\\211PNG\\r\\n\\032\\nfake';; cat*) printf 'file-bytes';; ls*) echo "-rw drwx";; esac;;
esac
"""
FAKE_AVAHI = """#!/bin/sh
echo '=;wlo1;IPv4;adb-ABC;_adb-tls-connect._tcp;local;phone.local;192.168.1.50;37000;"txt"'
echo '=;wlo1;IPv4;adb-PUB;_adb-tls-connect._tcp;local;evil.local;8.8.8.8;5555;"txt"'
"""


class RunnerTest(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp(prefix="padb-")
        for n, body in (("adb", FAKE_ADB), ("avahi", FAKE_AVAHI)):
            p = os.path.join(self.d, n)
            open(p, "w").write(body)
            os.chmod(p, 0o755)
        self.conf = {"adb": f"{self.d}/adb", "avahi": f"{self.d}/avahi", "sock": f"{self.d}/s/adb.sock", "home": self.d,
                     "grant": f"{self.d}/grant.json", "state": f"{self.d}/state", "grant_uid": os.getuid()}
        self.m = load("phone_adb.py", **{"@adb@": "x", "@avahiBrowse@": "x", "@sock@": "x", "@home@": "x",
                                         "@grantFile@": "x", "@stateDir@": "x"})
        os.environ["SUDO_UID"] = str(os.getuid())

    def grant(self, **kw):
        g = {"uid": os.getuid(), "granted_at": time.time(), "idle_s": 600, "max_until": time.time() + 3600}
        g.update(kw)
        open(self.conf["grant"], "w").write(json.dumps(g))
        os.chmod(self.conf["grant"], 0o644)

    def run_cmd(self, *argv):
        raw = io.BytesIO()
        buf = io.TextIOWrapper(raw, encoding="utf-8")  # has .buffer, like a real stdout
        code = 0
        with redirect_stdout(buf):
            try:
                self.m.main(list(argv), self.conf)
            except SystemExit as e:
                code = e.code or 0
        buf.flush()
        self.last_raw = raw.getvalue()
        return code, raw.getvalue().decode("utf-8", "replace")

    # --- the gate -------------------------------------------------------------------------------
    def test_shell_refused_without_a_grant(self):
        code, out = self.run_cmd("shell", "ls")
        self.assertEqual(code, 77)
        self.assertIn("phone adb authorize", out)

    def test_shell_works_with_a_grant_and_passes_the_exit_code(self):
        self.grant()
        code, _ = self.run_cmd("shell", "echo", "hi")
        self.assertEqual(code, 3)  # the fake adb's own status

    def test_grant_for_another_user_is_refused(self):
        self.grant(uid=os.getuid() + 1)
        self.assertEqual(self.run_cmd("shell", "ls")[0], 77)

    def test_expired_grants_are_refused(self):
        self.grant(max_until=time.time() - 1)
        self.assertEqual(self.run_cmd("shell", "ls")[0], 77)
        self.grant(idle_s=1, granted_at=time.time() - 100)
        self.assertEqual(self.run_cmd("shell", "ls")[0], 77)

    def test_use_extends_the_idle_window(self):
        self.grant(idle_s=60, granted_at=time.time() - 50)
        self.run_cmd("shell", "ls")  # uses it, refreshing last_used
        info = self.m.Gate(self.conf).info(os.getuid())
        self.assertTrue(info["active"])
        self.assertGreater(info["idle_left_s"], 55)

    def test_a_grant_writable_by_others_is_ignored(self):
        self.grant()
        os.chmod(self.conf["grant"], 0o666)
        self.assertEqual(self.run_cmd("shell", "ls")[0], 77)

    def test_unknown_caller_is_refused(self):
        self.grant()
        os.environ.pop("SUDO_UID")
        self.assertEqual(self.run_cmd("shell", "ls")[0], 77)

    # --- free tier -------------------------------------------------------------------------------
    def test_status_and_discovery_ignore_public_addresses(self):
        code, out = self.run_cmd("status", "--scan")
        d = json.loads(out)
        self.assertTrue(d["server"])
        self.assertEqual([x["address"] for x in d["advertised"]], ["192.168.1.50"])

    def test_path_validation(self):
        for bad in ("/etc/passwd", "/sdcard/../data/x", "/sdcard/a'b", "sdcard/x"):
            code, out = self.run_cmd("pull", bad)
            self.assertEqual(code, 1, bad)
        code, _ = self.run_cmd("ls", "/sdcard/DCIM")
        self.assertEqual(code, 0)

    def test_pull_and_screenshot_return_the_phone_bytes(self):
        code, out = self.run_cmd("pull", "/sdcard/Download/a.txt")
        self.assertEqual((code, out), (0, "file-bytes"))
        code, out = self.run_cmd("screenshot")
        self.assertEqual(code, 0)
        self.assertTrue(self.last_raw.startswith(b"\x89PNG"))  # raw bytes, not decoded text

    def test_connect_rejects_public_targets_and_pairing_needs_six_digits(self):
        self.assertEqual(self.run_cmd("connect", "8.8.8.8:5555")[0], 1)
        self.assertEqual(self.run_cmd("pair", "192.168.1.50:41000", "12ab56")[0], 1)
        code, out = self.run_cmd("pair", "192.168.1.50:41000", "123456")
        self.assertEqual(code, 0)
        self.assertTrue(json.loads(out)["paired"])

    def test_connect_discovers_the_phone(self):
        code, out = self.run_cmd("connect")
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(out)["target"], "192.168.1.50:37000")

    def test_watcher_connects_when_the_phone_is_advertised(self):
        # a fake adb that reports no device first, so the watcher must discover and connect
        log = os.path.join(self.d, "calls")
        open(self.conf["adb"], "w").write("#!/bin/sh\necho \"$@\" >> %s\ncase \"$*\" in *devices*) echo 'List of devices attached';; "
                                          "*server*) sleep 30;; esac\n" % log)
        self.m.cmd_watch(self.conf, types.SimpleNamespace(interval=0), iterations=1)
        calls = open(log).read()
        self.assertIn("connect 192.168.1.50:37000", calls)


    def test_connect_tries_every_advertised_device(self):
        """Another phone on the network advertises too; only the paired one answers."""
        open(self.conf["avahi"], "w").write("#!/bin/sh\n"
            "echo '=;wlo1;IPv4;adb-OTHER;_adb-tls-connect._tcp;local;o.local;192.168.1.99;4000;\"t\"'\n"
            "echo '=;wlo1;IPv4;adb-OTHER;_adb-tls-connect._tcp;local;o.local;192.168.1.99;4000;\"t\"'\n"  # duplicate (v4/v6 twin)
            "echo '=;wlo1;IPv4;adb-MINE;_adb-tls-connect._tcp;local;m.local;192.168.1.50;37000;\"t\"'\n")
        open(self.conf["adb"], "w").write("#!/bin/sh\ncase \"$1\" in connect) case \"$2\" in "
            "*192.168.1.99*) echo 'failed to connect to 192.168.1.99:4000';; *) echo \"connected to $2\";; esac;; "
            "devices) printf 'List of devices attached\\n';; esac\n")
        code, out = self.run_cmd("connect")
        d = json.loads(out)
        self.assertEqual((code, d["connected"], d["target"], d["tried"]), (0, True, "192.168.1.50:37000", 2))


class GrantTest(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp(prefix="padb-g-")
        self.path = os.path.join(self.d, "run", "grant.json")
        self.m = load("phone_adb_grant.py", **{"@grantFile@": self.path, "@stateDir@": os.path.join(self.d, "state"),
                                                "@idleMinutes@": "30", "@maxHours@": "8"})
        os.environ.pop("PKEXEC_UID", None)

    def call(self, *argv):
        buf = io.StringIO()
        code = 0
        with redirect_stdout(buf):
            try:
                self.m.main(list(argv))
            except SystemExit as e:
                code = e.code or 0
        return code, json.loads(buf.getvalue())

    def test_grant_refused_without_pkexec(self):
        code, out = self.call("--grant")
        self.assertEqual(code, 1)
        self.assertIn("polkit", out["error"])
        self.assertFalse(os.path.exists(self.path))

    def test_grant_refused_for_root(self):
        os.environ["PKEXEC_UID"] = "0"
        self.assertEqual(self.call("--grant")[0], 1)

    def test_grant_writes_a_world_readable_not_writable_file_and_revoke_removes_it(self):
        os.environ["PKEXEC_UID"] = "1000"
        code, out = self.call("--grant", "--idle-minutes", "10", "--max-hours", "2")
        self.assertEqual(code, 0)
        g = json.load(open(self.path))
        self.assertEqual((g["uid"], g["idle_s"]), (1000, 600))
        self.assertEqual(stat.S_IMODE(os.stat(self.path).st_mode), 0o644)
        self.assertEqual(self.call("--revoke")[0], 0)
        self.assertFalse(os.path.exists(self.path))

    def test_limits_are_enforced(self):
        os.environ["PKEXEC_UID"] = "1000"
        self.assertEqual(self.call("--grant", "--idle-minutes", "9999")[0], 1)
        self.assertEqual(self.call("--grant", "--max-hours", "0")[0], 1)
        self.assertEqual(self.call("--grant", "--evil")[0], 1)


if __name__ == "__main__":
    unittest.main()
