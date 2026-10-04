"""Runs inside a bench pod in the agent namespace (label app=agent, so the
agent's network policy applies: API server and sandbox port 8888 only).
Prints one JSON line per sample.

Usage: bench_client.py WARM_SAMPLES COLD_SAMPLES OVERHEAD_REPS BURST

1. Startup latency, from creating the object to the first successful run:
   - warm: a SandboxClaim on the warm pool (what the agent does)
   - cold: a Sandbox created directly from the same template, under gVisor
     and under runc
   For each it records when the object reports Ready and when the executor
   first answers POST /run, which can be earlier: readiness is an exec probe
   on a 5s period.
   - burst: BURST claims at once against a full pool, so the ones beyond the
     pool size wait for the pool to refill.
2. Runtime overhead: the same workloads, submitted through the executor, in a
   gVisor and a runc sandbox built from the same template (same hardening,
   image and memory limit; 2 CPUs each instead of 500m, see OVERHEAD_CPU). Workloads time themselves inside the sandbox, so
   HTTP and interpreter start-up are excluded except where measured on
   purpose.

Standard library only; reaches the API server by IP, so it needs no DNS.
"""

import concurrent.futures
import copy
import json
import os
import socket
import ssl
import sys
import time
import urllib.error
import urllib.request

SA_DIR = "/var/run/secrets/kubernetes.io/serviceaccount"
API = f"https://{os.environ['KUBERNETES_SERVICE_HOST']}:{os.environ['KUBERNETES_SERVICE_PORT']}"
NS = "sandboxes"
POOL = "python-gvisor"
EXT = f"{API}/apis/extensions.agents.x-k8s.io/v1beta1/namespaces/{NS}"
CORE = f"{API}/apis/agents.x-k8s.io/v1beta1/namespaces/{NS}"
POLL_S = 0.02
TTL_S = 900  # shutdownTime backstop on everything we create

_ssl = ssl.create_default_context(cafile=f"{SA_DIR}/ca.crt")


def emit(**fields):
    print(json.dumps(fields), flush=True)


def k8s(method, url, body=None):
    with open(f"{SA_DIR}/token") as f:
        token = f.read().strip()
    req = urllib.request.Request(url, method=method, data=json.dumps(body).encode() if body else None,
                                 headers={"Authorization": f"Bearer {token}",
                                          "Content-Type": "application/json"})
    with urllib.request.urlopen(req, context=_ssl, timeout=10) as r:
        return json.load(r)


def get_or_none(url):
    try:
        return k8s("GET", url)
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return None
        raise


def ready(obj):
    return any(c.get("type") == "Ready" and c.get("status") == "True"
               for c in (obj or {}).get("status", {}).get("conditions", []))


def shutdown_time():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() + TTL_S))


def run(ip, code, timeout_s=30):
    req = urllib.request.Request(f"http://{ip}:8888/run", method="POST",
                                 data=json.dumps({"code": code, "timeout_s": timeout_s}).encode(),
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout_s + 10) as r:
        return json.load(r)


def answers(ip):
    """True once the executor accepts a connection and runs code. The short
    connect timeout keeps polling granularity fine while the pod's network
    isn't up yet (packets dropped rather than refused)."""
    try:
        socket.create_connection((ip, 8888), timeout=0.3).close()
        return run(ip, "print(1)", 5).get("stdout") == "1\n"
    except OSError:
        return False


def wait_gone(url, timeout_s=120):
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline and get_or_none(url) is not None:
        time.sleep(0.5)


def wait_pool_full(timeout_s=180):
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        pool = k8s("GET", f"{EXT}/sandboxwarmpools/{POOL}")
        want = pool["spec"]["replicas"]
        st = pool.get("status", {})
        if st.get("readyReplicas") == want and st.get("replicas") == want:
            time.sleep(2)  # let the last refill settle so it doesn't overlap the next sample
            return
        time.sleep(0.5)
    raise TimeoutError("warm pool did not refill")


def pod_template(runtime, cpu=None):
    tmpl = k8s("GET", f"{EXT}/sandboxtemplates/{POOL}")
    pt = copy.deepcopy(tmpl["spec"]["podTemplate"])
    if runtime == "runc":
        pt["spec"].pop("runtimeClassName", None)
    if cpu:
        for c in pt["spec"]["containers"]:
            c["resources"]["limits"]["cpu"] = c["resources"]["requests"]["cpu"] = cpu
    return pt


def create_sandbox(name, runtime, cpu=None):
    k8s("POST", f"{CORE}/sandboxes", {
        "apiVersion": "agents.x-k8s.io/v1beta1", "kind": "Sandbox",
        "metadata": {"name": name, "labels": {"bench": "p1"}},
        "spec": {"podTemplate": pod_template(runtime, cpu),
                 "shutdownTime": shutdown_time(), "shutdownPolicy": "Delete"},
    })


def sandbox_ip(sb):
    ips = (sb or {}).get("status", {}).get("podIPs") or []
    return ips[0] if ips else None


def time_cold(name, runtime):
    url = f"{CORE}/sandboxes/{name}"
    t0 = time.monotonic()
    create_sandbox(name, runtime)
    t_ready = t_run = ip = None
    while t_ready is None or t_run is None:
        if time.monotonic() - t0 > 180:
            raise TimeoutError(f"{name} not ready")
        sb = get_or_none(url)
        now = time.monotonic()
        if t_ready is None and ready(sb):
            t_ready = now
        ip = ip or sandbox_ip(sb)
        if t_run is None and ip and answers(ip):
            t_run = time.monotonic()
        time.sleep(POLL_S)
    k8s("DELETE", url)
    wait_gone(url)
    return (t_ready - t0) * 1000, (t_run - t0) * 1000


def time_warm(name):
    url = f"{EXT}/sandboxclaims/{name}"
    t0 = time.monotonic()
    k8s("POST", f"{EXT}/sandboxclaims", {
        "apiVersion": "extensions.agents.x-k8s.io/v1beta1", "kind": "SandboxClaim",
        "metadata": {"name": name},
        "spec": {"warmPoolRef": {"name": POOL},
                 "lifecycle": {"shutdownTime": shutdown_time(), "shutdownPolicy": "Delete"}},
    })
    while True:
        if time.monotonic() - t0 > 180:
            raise TimeoutError(f"{name} not ready")
        claim = get_or_none(url)
        sb_name = (claim or {}).get("status", {}).get("sandbox", {}).get("name")
        if ready(claim) and sb_name:
            ip = sandbox_ip(k8s("GET", f"{CORE}/sandboxes/{sb_name}"))
            if ip:
                break
        time.sleep(POLL_S)
    t_ready = time.monotonic()
    while not answers(ip):
        time.sleep(POLL_S)
    t_run = time.monotonic()
    k8s("DELETE", url)
    wait_gone(url)
    return (t_ready - t0) * 1000, (t_run - t0) * 1000


# Each workload prints the seconds it took, measured inside the sandbox.
# Sized so runc takes well under a second each with the template's 500m CPU.
WORKLOADS = [
    ("cpu-python", "CPU: pure-Python loop, 2M iterations", """
import time
t = time.perf_counter(); x = 0
for i in range(2_000_000): x += i * i
print(time.perf_counter() - t)
"""),
    ("cpu-sha256", "CPU: SHA-256 of 64 MiB (C code, no syscalls)", """
import hashlib, time
b = b"x" * 2**20; h = hashlib.sha256()
t = time.perf_counter()
for _ in range(64): h.update(b)
print(time.perf_counter() - t)
"""),
    ("syscall-getppid", "Syscalls: 100k getppid()", """
import os, time
t = time.perf_counter()
for _ in range(100_000): os.getppid()
print(time.perf_counter() - t)
"""),
    ("file-stat", "File metadata: 50k stat() on /tmp", """
import os, time
open("/tmp/s", "w").close()
t = time.perf_counter()
for _ in range(50_000): os.stat("/tmp/s")
print(time.perf_counter() - t)
"""),
    ("file-small", "Small files: 2,000 x create, write 4 KiB, close, unlink in /tmp", """
import os, time
d = b"x" * 4096
t = time.perf_counter()
for i in range(2000):
    p = f"/tmp/f{i}"
    with open(p, "wb") as f: f.write(d)
    os.unlink(p)
print(time.perf_counter() - t)
"""),
    ("io-write", "Sequential write: 32 MiB to /tmp in 1 MiB chunks, then fsync", """
import os, time
b = b"x" * 2**20
t = time.perf_counter()
with open("/tmp/big", "wb") as f:
    for _ in range(32): f.write(b)
    f.flush(); os.fsync(f.fileno())
print(time.perf_counter() - t)
os.unlink("/tmp/big")
"""),
    ("io-read", "Sequential read: 32 MiB from /tmp in 1 MiB chunks (written just before)", """
import os, time
b = b"x" * 2**20
with open("/tmp/big", "wb") as f:
    for _ in range(32): f.write(b)
t = time.perf_counter()
with open("/tmp/big", "rb") as f:
    while f.read(2**20): pass
print(time.perf_counter() - t)
os.unlink("/tmp/big")
"""),
    ("spawn", "Process spawn: 50 x subprocess.run(['/bin/true'])", """
import subprocess, time
t = time.perf_counter()
for _ in range(50): subprocess.run(["/bin/true"], check=True)
print(time.perf_counter() - t)
"""),
    ("net-loopback", "Network stack: 2,000 TCP round trips of 64 bytes over 127.0.0.1", """
import socket, threading, time
srv = socket.socket(); srv.bind(("127.0.0.1", 0)); srv.listen(1)
def echo():
    c, _ = srv.accept()
    while d := c.recv(64): c.sendall(d)
threading.Thread(target=echo, daemon=True).start()
s = socket.create_connection(srv.getsockname())
s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
msg = b"x" * 64
t = time.perf_counter()
for _ in range(2000):
    s.sendall(msg); n = 0
    while n < 64: n += len(s.recv(64 - n))
print(time.perf_counter() - t)
"""),
]


# The template's 500m CPU limit throttles in 100 ms CFS periods, which made
# short workloads swing by 2x between runs. The overhead pair gets 2 CPUs
# (both runtimes alike) so the comparison measures the runtime, not the quota.
OVERHEAD_CPU = "2"


def overhead(reps):
    ips = {}
    for rt in ("gvisor", "runc"):
        name = f"bench-overhead-{rt}"
        create_sandbox(name, rt, OVERHEAD_CPU)
        url = f"{CORE}/sandboxes/{name}"
        deadline = time.monotonic() + 180
        while True:
            ip = sandbox_ip(get_or_none(url))
            if ip and answers(ip):
                ips[rt] = ip
                break
            if time.monotonic() > deadline:
                raise TimeoutError(f"{name} not answering")
            time.sleep(0.2)
    for rt, ip in ips.items():
        r = run(ip, "print(open('/proc/version').read().strip())")
        emit(kind="runtime", runtime=rt, proc_version=r["stdout"].strip(), cpu=OVERHEAD_CPU)
        run(ip, "pass")  # warm the interpreter's page cache before timing

    for rep in range(reps):
        # Alternate which runtime goes first, so drift hits both equally.
        order = ["gvisor", "runc"] if rep % 2 == 0 else ["runc", "gvisor"]
        for rt in order:
            # Interpreter start-up and the agent's round trip for an empty run.
            t = time.monotonic()
            r = run(ips[rt], "pass")
            emit(kind="overhead", workload="empty-run", runtime=rt, rep=rep,
                 seconds=r["duration_ms"] / 1000, round_trip_s=time.monotonic() - t)
            for wid, _, code in WORKLOADS:
                r = run(ips[rt], code)
                if r["exit_code"] != 0 or r["timed_out"]:
                    emit(kind="error", workload=wid, runtime=rt, rep=rep,
                         stderr=r["stderr"][-500:], timed_out=r["timed_out"])
                    continue
                emit(kind="overhead", workload=wid, runtime=rt, rep=rep,
                     seconds=float(r["stdout"].split()[0]))
    for rt in ips:
        k8s("DELETE", f"{CORE}/sandboxes/bench-overhead-{rt}")


def burst(n):
    wait_pool_full()
    stamp = int(time.time())
    with concurrent.futures.ThreadPoolExecutor(n) as ex:
        times = list(ex.map(time_warm, [f"bench-burst-{stamp}-{i}" for i in range(n)]))
    pool = k8s("GET", f"{EXT}/sandboxwarmpools/{POOL}")["spec"]["replicas"]
    for i, (r, f) in enumerate(sorted(times, key=lambda t: t[1])):
        emit(kind="burst", i=i, n=n, pool=pool, ready_ms=r, first_run_ms=f)


def main():
    warm_n, cold_n, reps, burst_n = map(int, sys.argv[1:5])
    emit(kind="workloads", items=[{"id": w, "desc": d} for w, d, _ in WORKLOADS])
    stamp = int(time.time())
    for i in range(warm_n):
        wait_pool_full()
        r, f = time_warm(f"bench-warm-{stamp}-{i}")
        emit(kind="latency", mode="warm-claim", runtime="gvisor", i=i, ready_ms=r, first_run_ms=f)
    for i in range(cold_n):
        for rt in ("gvisor", "runc"):
            wait_pool_full()
            r, f = time_cold(f"bench-cold-{rt}-{stamp}-{i}", rt)
            emit(kind="latency", mode="cold-sandbox", runtime=rt, i=i, ready_ms=r, first_run_ms=f)
    if burst_n:
        burst(burst_n)
    if reps:
        overhead(reps)


if __name__ == "__main__":
    main()
