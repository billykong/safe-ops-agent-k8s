"""A stand-in for an external incident tracker (P3 milestone 3): the kind
of SaaS API a tool needs a secret for. GET /incidents and
GET /incidents/<id>, only with `Authorization: Bearer <token>` matching
the mounted token. Standard library only."""
import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TOKEN_FILE = os.environ.get("TOKEN_FILE", "/var/run/secrets/safe-ops.io/tracker/token")

INCIDENTS = {
    "INC-1001": {"id": "INC-1001", "status": "open", "service": "workloads/web", "severity": "high",
                 "title": "web latency high under load",
                 "description": "p99 latency is 4x normal since traffic doubled. One replica can't keep up; "
                                "capacity planning says scale web to 3 replicas."},
    "INC-1002": {"id": "INC-1002", "status": "open", "service": "workloads/web", "severity": "medium",
                 "title": "web pods serving a stale config",
                 "description": "A config change didn't reach the running pods. A rolling restart of web picks it up."},
    "INC-1003": {"id": "INC-1003", "status": "open", "service": "workloads/web", "severity": "low",
                 "title": "noisy log line", "description": "Cosmetic. No action needed on the cluster.",
                 # For the gateway's result cap: a large attachment.
                 "attachment": "x" * 200_000},
}


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/healthz":
            return self._send(200, {"ok": True})
        with open(TOKEN_FILE) as f:
            token = f.read().strip()
        if not token or self.headers.get("Authorization") != f"Bearer {token}":
            return self._send(401, {"error": "invalid or missing token"})
        if self.path == "/incidents":
            return self._send(200, [{k: v for k, v in i.items() if k in ("id", "title", "severity", "status")}
                                    for i in INCIDENTS.values() if i["status"] == "open"])
        if self.path.startswith("/incidents/"):
            inc = INCIDENTS.get(self.path.rsplit("/", 1)[1])
            return self._send(200, inc) if inc else self._send(404, {"error": "no such incident"})
        return self._send(404, {"error": "not found"})

    def log_message(self, fmt, *args):
        print(json.dumps({"event": "request", "line": fmt % args}), flush=True)


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
