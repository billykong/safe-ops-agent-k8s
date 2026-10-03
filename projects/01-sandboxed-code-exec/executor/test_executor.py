"""Tests for executor.py against a real server on a random local port.

Run: python3 -m unittest -v test_executor.py
"""

import json
import threading
import time
import unittest
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer

import executor


class ExecutorTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # RLIMIT_NPROC counts every process of the uid. On a dev host that's
        # the whole user session, so the cap is exercised in-cluster instead
        # (scripts/attack-demos.sh).
        executor.MAX_PROCS = 0
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), executor.Handler)
        cls.base = f"http://127.0.0.1:{cls.server.server_address[1]}"
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()

    def post(self, body, raw=None):
        data = raw if raw is not None else json.dumps(body).encode()
        req = urllib.request.Request(f"{self.base}/run", data=data, method="POST",
                                     headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                return r.status, json.load(r)
        except urllib.error.HTTPError as e:
            return e.code, json.load(e)

    def test_healthz(self):
        with urllib.request.urlopen(f"{self.base}/healthz") as r:
            self.assertEqual(r.status, 200)

    def test_stdout_and_exit_zero(self):
        status, res = self.post({"code": "print('hello')"})
        self.assertEqual(status, 200)
        self.assertEqual(res["stdout"], "hello\n")
        self.assertEqual(res["exit_code"], 0)
        self.assertFalse(res["timed_out"])

    def test_stderr_and_nonzero_exit(self):
        _, res = self.post({"code": "import sys; print('boom', file=sys.stderr); sys.exit(3)"})
        self.assertEqual(res["stderr"], "boom\n")
        self.assertEqual(res["exit_code"], 3)

    def test_timeout_kills_run(self):
        start = time.monotonic()
        _, res = self.post({"code": "import time; time.sleep(30)", "timeout_s": 1})
        self.assertTrue(res["timed_out"])
        self.assertLess(time.monotonic() - start, 5)

    def test_background_children_cannot_hold_run_open(self):
        # The main process exits at once, but a child keeps stdout open.
        code = "import subprocess; subprocess.Popen(['sleep', '30']); print('done')"
        start = time.monotonic()
        _, res = self.post({"code": code, "timeout_s": 2})
        self.assertIn("done", res["stdout"])
        self.assertLess(time.monotonic() - start, 5)

    def test_memory_is_capped(self):
        code = "x = b'1' * (512 * 2**20)\nprint('allocated')"
        _, res = self.post({"code": code})
        self.assertIn("MemoryError", res["stderr"])

    def test_output_is_capped(self):
        _, res = self.post({"code": "print('x' * 1_000_000)"})
        self.assertTrue(res["truncated"])
        self.assertEqual(len(res["stdout"]), executor.MAX_OUTPUT_BYTES)

    def test_timeout_is_capped(self):
        # Asking for a huge timeout still gets MAX_TIMEOUT_S; check it's accepted.
        _, res = self.post({"code": "print(1)", "timeout_s": 10_000})
        self.assertEqual(res["exit_code"], 0)

    def test_rejects_bad_requests(self):
        self.assertEqual(self.post(None, raw=b"not json")[0], 400)
        self.assertEqual(self.post({"nocode": 1})[0], 400)
        self.assertEqual(self.post({"code": 123})[0], 400)
        self.assertEqual(self.post({"code": "1", "timeout_s": -1})[0], 400)
        self.assertEqual(self.post({"code": "1", "timeout_s": True})[0], 400)

    def test_rejects_oversized_body(self):
        status, _ = self.post({"code": "#" * (executor.MAX_BODY_BYTES + 1)})
        self.assertEqual(status, 413)

    def test_one_run_at_a_time(self):
        results = {}
        slow = threading.Thread(target=lambda: results.update(
            slow=self.post({"code": "import time; time.sleep(2)", "timeout_s": 5})))
        slow.start()
        time.sleep(0.5)
        status, _ = self.post({"code": "print(1)"})
        slow.join()
        self.assertEqual(status, 409)
        self.assertEqual(results["slow"][0], 200)


if __name__ == "__main__":
    unittest.main()
