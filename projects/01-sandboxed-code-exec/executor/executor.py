"""Minimal code executor that runs inside the sandbox pod.

POST /run   {"code": "...", "timeout_s": 10}
         -> {"stdout", "stderr", "exit_code", "timed_out", "duration_ms", "truncated"}
GET  /healthz

Standard library only. The executor is not a security boundary: user code
runs as the same uid and can kill it. Isolation comes from gVisor, the pod
hardening and NetworkPolicy. The executor's job is bounded, predictable runs:
a wall-clock timeout that kills the whole process group, capped output and
request size, and one run at a time.
"""

import json
import os
import resource
import signal
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("EXECUTOR_PORT", "8888"))
WORKDIR = os.environ.get("EXECUTOR_WORKDIR", "/tmp")
MAX_BODY_BYTES = 256 * 1024
MAX_OUTPUT_BYTES = 64 * 1024
DEFAULT_TIMEOUT_S = 10
MAX_TIMEOUT_S = 60

_busy = threading.Lock()


def _read_capped(stream, limit, out):
    """Read a stream to EOF, keeping at most `limit` bytes. Draining the rest
    stops the child from blocking on a full pipe."""
    kept = bytearray()
    truncated = False
    while chunk := stream.read(8192):
        room = limit - len(kept)
        if room > 0:
            kept += chunk[:room]
        if len(chunk) > room:
            truncated = True
    out["data"] = kept.decode("utf-8", errors="replace")
    out["truncated"] = truncated


def _limit_child(cpu_s):
    # Runs in the child before exec. A CPU-time cap backs up the wall-clock
    # timeout; memory and pids are capped by the pod's cgroup.
    resource.setrlimit(resource.RLIMIT_CPU, (cpu_s, cpu_s))
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))


def run_code(code, timeout_s):
    with tempfile.TemporaryDirectory(dir=WORKDIR) as tmp:
        path = os.path.join(tmp, "main.py")
        with open(path, "w") as f:
            f.write(code)

        start = time.monotonic()
        proc = subprocess.Popen(
            [sys.executable, "-I", "-B", path],
            cwd=tmp,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            start_new_session=True,  # own process group, so we can kill it all
            preexec_fn=lambda: _limit_child(timeout_s + 1),
            env={"PATH": "/usr/local/bin:/usr/bin:/bin", "HOME": tmp, "PYTHONUNBUFFERED": "1"},
        )
        out, err = {}, {}
        readers = [
            threading.Thread(target=_read_capped, args=(proc.stdout, MAX_OUTPUT_BYTES, out)),
            threading.Thread(target=_read_capped, args=(proc.stderr, MAX_OUTPUT_BYTES, err)),
        ]
        for t in readers:
            t.start()

        timed_out = False
        try:
            proc.wait(timeout=timeout_s)
        except subprocess.TimeoutExpired:
            timed_out = True
        # Kill the group either way: the main process may have exited and left
        # background children holding the pipes open.
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        proc.wait()
        for t in readers:
            t.join(timeout=5)
        duration_ms = int((time.monotonic() - start) * 1000)

    return {
        "stdout": out.get("data", ""),
        "stderr": err.get("data", ""),
        "exit_code": proc.returncode,
        "timed_out": timed_out,
        "duration_ms": duration_ms,
        "truncated": bool(out.get("truncated") or err.get("truncated")),
    }


class Handler(BaseHTTPRequestHandler):
    server_version = "sandbox-executor"
    sys_version = ""

    def _send(self, status, body):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/healthz":
            self._send(200, {"ok": True})
        else:
            self._send(404, {"error": "not found"})

    def do_POST(self):
        if self.path != "/run":
            return self._send(404, {"error": "not found"})
        try:
            length = int(self.headers.get("Content-Length", ""))
        except ValueError:
            return self._send(411, {"error": "Content-Length required"})
        if length > MAX_BODY_BYTES:
            return self._send(413, {"error": f"body over {MAX_BODY_BYTES} bytes"})
        try:
            req = json.loads(self.rfile.read(length))
            code = req["code"]
            timeout_s = req.get("timeout_s", DEFAULT_TIMEOUT_S)
            if not isinstance(code, str):
                raise TypeError("code must be a string")
            if not isinstance(timeout_s, (int, float)) or isinstance(timeout_s, bool) or timeout_s <= 0:
                raise TypeError("timeout_s must be a positive number")
        except (ValueError, KeyError, TypeError) as e:
            return self._send(400, {"error": f"bad request: {e}"})

        if not _busy.acquire(blocking=False):
            return self._send(409, {"error": "a run is already in progress"})
        try:
            result = run_code(code, int(min(timeout_s, MAX_TIMEOUT_S)) or 1)
        finally:
            _busy.release()
        self._send(200, result)

    def log_message(self, fmt, *args):
        sys.stderr.write("%s %s\n" % (self.address_string(), fmt % args))


def main():
    server = ThreadingHTTPServer(("", PORT), Handler)
    signal.signal(signal.SIGTERM, lambda *_: threading.Thread(target=server.shutdown).start())
    print(f"executor listening on :{PORT}", file=sys.stderr, flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
