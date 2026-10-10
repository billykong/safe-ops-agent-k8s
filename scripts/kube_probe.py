"""Call the Kubernetes API with this pod's own service account token.

    kubectl exec -i -n agent deploy/agent-worker -- python - METHOD PATH [BODY] < kube_probe.py

Prints the HTTP status. Used by the audit suite to act as the agent with
its real, pod-bound token: impersonation (kubectl --as) is audited under
the impersonator's rules, not the agent's.
"""
import json
import os
import ssl
import sys
import urllib.error
import urllib.request

SA = "/var/run/secrets/kubernetes.io/serviceaccount"
method, path = sys.argv[1], sys.argv[2]
body = sys.argv[3].encode() if len(sys.argv) > 3 else None
token = open(f"{SA}/token").read().strip()
ctx = ssl.create_default_context(cafile=f"{SA}/ca.crt")
req = urllib.request.Request(
    # By address: the agent's DNS is fenced to the names it needs.
    f"https://{os.environ['KUBERNETES_SERVICE_HOST']}:{os.environ['KUBERNETES_SERVICE_PORT']}" + path, data=body, method=method,
    headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"})
try:
    with urllib.request.urlopen(req, context=ctx, timeout=10) as r:
        print(r.status)
except urllib.error.HTTPError as e:
    print(e.code, json.loads(e.read() or b"{}").get("reason", ""))
