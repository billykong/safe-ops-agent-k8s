"""Minimal agent: claim a sandbox, run code in it, release it.

No LLM yet; the code comes from the TASK_CODE env var. This proves the
plumbing: the agent pod holds the Kubernetes credentials, the sandbox holds
none, and the agent talks to the sandbox only through the executor API.

Standard library only. Talks to the API server by IP from the in-cluster env
vars, so it needs no DNS.
"""

import json
import os
import ssl
import sys
import time
import urllib.error
import urllib.request

SA_DIR = "/var/run/secrets/kubernetes.io/serviceaccount"
API = f"https://{os.environ['KUBERNETES_SERVICE_HOST']}:{os.environ['KUBERNETES_SERVICE_PORT']}"
NS = os.environ.get("SANDBOX_NAMESPACE", "sandboxes")
WARM_POOL = os.environ.get("WARM_POOL", "python-gvisor")
CLAIM_NAME = os.environ.get("CLAIM_NAME") or f"agent-{os.environ.get('HOSTNAME', 'local')}"
TASK_CODE = os.environ.get("TASK_CODE", "print('hello from the sandbox')")
TASK_TIMEOUT_S = int(os.environ.get("TASK_TIMEOUT_S", "10"))
READY_TIMEOUT_S = 120
# Backstop: if the agent dies before releasing, the sandbox shuts down anyway.
CLAIM_TTL_S = 600

CLAIMS = f"{API}/apis/extensions.agents.x-k8s.io/v1beta1/namespaces/{NS}/sandboxclaims"
SANDBOXES = f"{API}/apis/agents.x-k8s.io/v1beta1/namespaces/{NS}/sandboxes"

_ssl = ssl.create_default_context(cafile=f"{SA_DIR}/ca.crt")


def log(event, **fields):
    print(json.dumps({"event": event, **fields}), flush=True)


def k8s(method, url, body=None):
    # Re-read the token each call: projected tokens are rotated on disk.
    with open(f"{SA_DIR}/token") as f:
        token = f.read().strip()
    req = urllib.request.Request(url, method=method, data=json.dumps(body).encode() if body else None,
                                 headers={"Authorization": f"Bearer {token}",
                                          "Content-Type": "application/json"})
    with urllib.request.urlopen(req, context=_ssl, timeout=10) as r:
        return json.load(r)


def is_ready(obj):
    return any(c.get("type") == "Ready" and c.get("status") == "True"
               for c in obj.get("status", {}).get("conditions", []))


def claim_sandbox():
    shutdown = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() + CLAIM_TTL_S))
    k8s("POST", CLAIMS, {
        "apiVersion": "extensions.agents.x-k8s.io/v1beta1",
        "kind": "SandboxClaim",
        "metadata": {"name": CLAIM_NAME},
        "spec": {"warmPoolRef": {"name": WARM_POOL},
                 "lifecycle": {"shutdownTime": shutdown, "shutdownPolicy": "Delete"}},
    })
    deadline = time.monotonic() + READY_TIMEOUT_S
    while time.monotonic() < deadline:
        claim = k8s("GET", f"{CLAIMS}/{CLAIM_NAME}")
        name = claim.get("status", {}).get("sandbox", {}).get("name")
        if is_ready(claim) and name:
            sandbox = k8s("GET", f"{SANDBOXES}/{name}")
            ips = sandbox.get("status", {}).get("podIPs") or []
            if ips:
                return name, ips[0]
        time.sleep(0.2)
    raise TimeoutError(f"claim {CLAIM_NAME} not ready after {READY_TIMEOUT_S}s")


def release():
    try:
        k8s("DELETE", f"{CLAIMS}/{CLAIM_NAME}")
        log("released", claim=CLAIM_NAME)
    except urllib.error.HTTPError as e:
        if e.code != 404:
            log("release_failed", claim=CLAIM_NAME, status=e.code)


def run_in_sandbox(ip, code, timeout_s):
    req = urllib.request.Request(f"http://{ip}:8888/run", method="POST",
                                 data=json.dumps({"code": code, "timeout_s": timeout_s}).encode(),
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout_s + 10) as r:
        return json.load(r)


def main():
    t0 = time.monotonic()
    try:
        name, ip = claim_sandbox()
        claim_ms = int((time.monotonic() - t0) * 1000)
        log("claimed", claim=CLAIM_NAME, sandbox=name, ip=ip, claim_ms=claim_ms)
        result = run_in_sandbox(ip, TASK_CODE, TASK_TIMEOUT_S)
        log("result", **result)
        return 0 if result["exit_code"] == 0 and not result["timed_out"] else 1
    except Exception as e:
        log("error", error=f"{type(e).__name__}: {e}")
        return 2
    finally:
        release()


if __name__ == "__main__":
    sys.exit(main())
