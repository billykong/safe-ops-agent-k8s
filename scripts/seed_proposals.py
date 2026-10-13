#!/usr/bin/env python3
"""Propose seeded test proposals (P4-15) as the seeder's identity.

Usage: seed_proposals.py CORPUS PREFIX [NAME ...]   (env: API, TOKEN, CA)

For each corpus entry (or just the NAMEs given): first record it in the
seed key (ConfigMap approval-system/seeded-proposals), then create the
ChangeRequest. In that order, so the controller never sees a seeded
request it doesn't know is seeded. The request is written as the agent
writes its own (same client, field manager and annotations), so an
approver can't tell them apart. Prints one line per proposal:
  <ChangeRequest name> <entry name> <expected> <rules>
Standard library and PyYAML only.
"""
import json
import os
import secrets
import ssl
import sys
import time
import urllib.request

import yaml

API, TOKEN, CA = os.environ["API"], os.environ["TOKEN"], os.environ["CA"]
CTX = ssl.create_default_context(cafile=CA)
SEED_KEY = f"{API}/api/v1/namespaces/approval-system/configmaps/seeded-proposals"
CRS = f"{API}/apis/approval.safe-ops.io/v1alpha1/namespaces/approvals/changerequests"


def call(method, url, body=None, ctype="application/json"):
    req = urllib.request.Request(url, method=method, data=json.dumps(body).encode() if body is not None else None,
                                 headers={"Authorization": f"Bearer {TOKEN}", "Content-Type": ctype})
    with urllib.request.urlopen(req, context=CTX, timeout=30) as r:
        return json.load(r)


def main():
    corpus, prefix, only = sys.argv[1], sys.argv[2], set(sys.argv[3:])
    entries = yaml.safe_load(open(corpus))["proposals"]
    unknown = only - {e["name"] for e in entries}
    if unknown:
        sys.exit(f"not in the corpus: {', '.join(sorted(unknown))}")
    stamp = int(time.time())
    for e in entries:
        if only and e["name"] not in only:
            continue
        name = f"{prefix}-{stamp}-{e['name']}"
        call("PATCH", SEED_KEY, {"data": {name: json.dumps({"expected": e["expected"], "reason": e["reason"]})}},
             "application/merge-patch+json")
        spec = dict(e["spec"])
        spec["scope"] = {"namespaces": [spec["action"]["target"]["namespace"]], "kinds": [spec["action"]["target"]["kind"]]}
        spec.setdefault("approvalWindowSeconds", 3600)
        # The agent's annotations: its workflow, and a W3C trace context.
        annotations = {"approval.safe-ops.io/workflow-id": f"{name}-change",
                       "approval.safe-ops.io/traceparent": f"00-{secrets.token_hex(16)}-{secrets.token_hex(8)}-01"}
        call("POST", CRS, {"apiVersion": "approval.safe-ops.io/v1alpha1", "kind": "ChangeRequest",
                           "metadata": {"name": name, "annotations": annotations}, "spec": spec})
        print(name, e["name"], e["expected"], e["rules"])


if __name__ == "__main__":
    main()
