"""Add the audit flags and mounts to the API server's static pod manifest.

    python3 audit_apiserver.py CONFIG_HASH < kube-apiserver.yaml > new.yaml

Idempotent: flags it owns are replaced, not duplicated, and the output is
the input unchanged if everything is already there. CONFIG_HASH (of the
policy and webhook config) goes in an annotation, so a changed policy
changes the manifest and the kubelet restarts the API server: it reads
the policy only at start.
"""
import sys

import yaml

FLAGS = {
    "--audit-policy-file": "/etc/kubernetes/audit/policy.yaml",
    # Local copy on the node: survives the sink being down.
    "--audit-log-path": "/var/log/kubernetes/audit/audit.log",
    "--audit-log-maxsize": "100",
    "--audit-log-maxbackup": "5",
    "--audit-log-format": "json",
    # The sink. Batches are sent at most 2s apart; a failed batch is
    # retried with backoff starting at 5s, then dropped from this path.
    "--audit-webhook-config-file": "/etc/kubernetes/audit/webhook.kubeconfig",
    "--audit-webhook-mode": "batch",
    "--audit-webhook-batch-max-wait": "2s",
    "--audit-webhook-initial-backoff": "5s",
}
MOUNTS = [
    ("audit-config", "/etc/kubernetes/audit", True, "Directory"),
    ("audit-log", "/var/log/kubernetes/audit", False, "DirectoryOrCreate"),
]
ANNOTATION = "safe-ops.io/audit-config-hash"


def patch(pod, config_hash):
    c = pod["spec"]["containers"][0]
    cmd = [a for a in c["command"] if a.split("=", 1)[0] not in FLAGS]
    cmd += [f"{k}={v}" for k, v in FLAGS.items()]
    c["command"] = cmd
    mounts = [m for m in c.get("volumeMounts", []) if m["name"] not in dict((n, 0) for n, *_ in MOUNTS)]
    vols = [v for v in pod["spec"].get("volumes", []) if v["name"] not in dict((n, 0) for n, *_ in MOUNTS)]
    for name, path, ro, kind in MOUNTS:
        mounts.append({"mountPath": path, "name": name, "readOnly": ro})
        vols.append({"hostPath": {"path": path, "type": kind}, "name": name})
    c["volumeMounts"] = mounts
    pod["spec"]["volumes"] = vols
    pod["metadata"].setdefault("annotations", {})[ANNOTATION] = config_hash
    return pod


def main():
    src = sys.stdin.read()
    pod = yaml.safe_load(src)
    before = yaml.safe_dump(pod, sort_keys=False)
    after = yaml.safe_dump(patch(pod, sys.argv[1]), sort_keys=False)
    sys.stdout.write(src if after == before else after)


if __name__ == "__main__":
    main()
