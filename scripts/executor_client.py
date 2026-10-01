"""Runs inside a client pod. Mode "full" exercises the executor API; mode
"reach" only checks whether the executor port is reachable."""
import json, sys, time, urllib.request

url, mode = sys.argv[1], sys.argv[2]

def run(code, timeout_s=10):
    req = urllib.request.Request(f"{url}/run", data=json.dumps({"code": code, "timeout_s": timeout_s}).encode(),
                                 method="POST", headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout_s + 10) as r:
        return json.load(r)

if mode == "reach":
    try:
        urllib.request.urlopen(f"{url}/healthz", timeout=3)
        print("REACHABLE")
    except Exception as e:
        print("UNREACHABLE", type(e).__name__)
    sys.exit(0)

failed = 0
def check(name, ok, got):
    global failed
    print(("PASS  " if ok else "FAIL  ") + name + ("" if ok else f": got {got}"))
    failed |= not ok

r = run("print('hello from', open('/proc/version').read().split()[2])")
check("runs code, under gVisor", r["exit_code"] == 0 and "gvisor" in r["stdout"], r)
r = run("import sys; sys.stderr.write('err'); sys.exit(4)")
check("stderr + exit code", r["stderr"] == "err" and r["exit_code"] == 4, r)
t = time.monotonic(); r = run("while True: pass", timeout_s=2)
check("timeout kills busy loop", r["timed_out"] and time.monotonic() - t < 6, r)
r = run("print('x' * 10**6)")
check("output capped", r["truncated"] and len(r["stdout"]) == 64 * 1024, {k: r[k] for k in ("truncated",)})
r = run("import socket; socket.create_connection(('1.1.1.1', 443), timeout=3)")
check("code has no egress", r["exit_code"] != 0 and "Timeout" in r["stderr"], r["stderr"][-200:])
r = run("open('/opt/x', 'w')")
check("code can't write outside /tmp", r["exit_code"] != 0, r["stderr"][-200:])
sys.exit(failed)
