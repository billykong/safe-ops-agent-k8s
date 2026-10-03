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
# Max processes for the sandbox's uid while user code runs (RLIMIT_NPROC).
# Under gVisor the pod's pids cgroup limit doesn't apply: guest processes are
# goroutines in the Sentry, not host tasks. gVisor does enforce RLIMIT_NPROC,
# and without it a fork bomb crashes the whole sandbox. The cap must fit the
# memory budget too: each forked Python soon copies its pages, and gVisor
# can't turn page-fault pressure from many processes into MemoryError. With
# 256 MiB, an exponential bomb crashed the sandbox at 64 and was contained
# at 32. The count includes the executor's own threads. 0 disables.
MAX_PROCS = int(os.environ.get("EXECUTOR_MAX_PROCS", "32"))
# Address-space cap per user-code process (RLIMIT_AS), so one big allocation
# fails with MemoryError. Without it, going over the pod memory limit kills
# the whole gVisor sandbox. Several processes can still add up past the pod
# limit; that crashes only this disposable sandbox. 0 disables.
MAX_MEMORY_MB = int(os.environ.get("EXECUTOR_MAX_MEMORY_MB", "192"))
# After each run, SIGKILL every process this uid may signal except ourselves
# (kill(-1)). Killing the process group misses code that called setsid(), and
# such a process would otherwise persist into later runs. Only safe where the
# executor's uid owns nothing else, i.e. inside the sandbox image, which sets
# this. On a dev host it would kill the user's whole session.
KILL_ALL_AFTER_RUN = os.environ.get("EXECUTOR_KILL_ALL_AFTER_RUN") == "1"

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
    # timeout; process and address-space caps stop fork and memory bombs
    # before they hit the pod's limits.
    resource.setrlimit(resource.RLIMIT_CPU, (cpu_s, cpu_s))
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    if MAX_PROCS:
        resource.setrlimit(resource.RLIMIT_NPROC, (MAX_PROCS, MAX_PROCS))
    if MAX_MEMORY_MB:
        limit = MAX_MEMORY_MB * 2**20
        resource.setrlimit(resource.RLIMIT_AS, (limit, limit))


def _others_alive():
    """Any live process besides PID 1 (tini) and the executor itself?
    Zombies don't count: tini reaps them."""
    me = os.getpid()
    for p in os.listdir("/proc"):
        if not p.isdigit() or int(p) in (1, me):
            continue
        try:
            with open(f"/proc/{p}/stat") as f:
                if f.read().rsplit(")", 1)[1].split()[0] != "Z":
                    return True
        except OSError:
            pass
    return False


def _kill_strays():
    # kill(-1) signals every process we may signal except ourselves and PID 1.
    # Repeat until none are left: a process mid-fork when the signal goes out
    # can produce a child that misses it (seen under gVisor with a setsid'd
    # double fork). Once the parents are dead nothing new can appear.
    for _ in range(40):
        try:
            os.kill(-1, signal.SIGKILL)
        except ProcessLookupError:
            return
        time.sleep(0.025)
        if not _others_alive():
            return
    print("warning: processes survived kill(-1) cleanup", file=sys.stderr, flush=True)


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
        if KILL_ALL_AFTER_RUN:
            _kill_strays()
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
