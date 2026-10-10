"""Send one DNS A query for each name given, to the pod's resolver, and
print "<name> <RCODE> <answers>". Standard library only, so it runs in
any Python pod via `kubectl exec ... python - NAME... < dns_probe.py`.
The red-team (scripts/red-team.sh) uses it to see what the DNS path does
with a name: answered, NXDOMAIN, or REFUSED by Cilium's DNS proxy."""
import random
import socket
import struct
import sys

RCODES = {0: "NOERROR", 1: "FORMERR", 2: "SERVFAIL", 3: "NXDOMAIN", 4: "NOTIMP", 5: "REFUSED"}
ns = next(l.split()[1] for l in open("/etc/resolv.conf") if l.startswith("nameserver"))
for name in sys.argv[1:]:
    qid = random.randrange(65536)
    q = struct.pack(">HHHHHH", qid, 0x0100, 1, 0, 0, 0)
    q += b"".join(bytes([len(p)]) + p.encode() for p in name.rstrip(".").split(".")) + b"\0" + struct.pack(">HH", 1, 1)
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(5)
    try:
        s.sendto(q, (ns, 53))
        r = s.recv(4096)
    except OSError as e:
        print(name, "NO-ANSWER", type(e).__name__)
        continue
    rcode, an = r[3] & 0xF, struct.unpack(">H", r[6:8])[0]
    print(name, RCODES.get(rcode, rcode), f"answers={an}")
