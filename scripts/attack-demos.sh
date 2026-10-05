#!/usr/bin/env bash
# Milestone 4: run attacks inside a claimed sandbox, submitted through the
# executor by an agent-identity pod, and record which layer stops each one.
# Host-side evidence (restart counts, Hubble drops) is gathered independently
# of what the attack code reports. Writes a Markdown report to
# projects/01-sandboxed-code-exec/results/attack-demos[-kata].md and exits
# non-zero if any attack gets through or the sandbox doesn't survive.
#
# Usage: scripts/attack-demos.sh [gvisor|kata]   (default gvisor)
set -euo pipefail
source "$(dirname "$0")/lib.sh"
cd "$(dirname "$0")/.."
NS=sandboxes
RUNTIME=${1:-gvisor}
case $RUNTIME in
  gvisor) POOL=python-gvisor; REPORT=projects/01-sandboxed-code-exec/results/attack-demos.md ;;
  kata)   POOL=python-kata;   REPORT=projects/01-sandboxed-code-exec/results/attack-demos-kata.md ;;
  *) echo "unknown runtime $RUNTIME"; exit 2 ;;
esac
CLAIM="attack-$(date +%s)"
TMP=$(mktemp -d)
trap 'kubectl delete sandboxclaim -n $NS $CLAIM --wait=false >/dev/null 2>&1 || true;
      kubectl delete pod -n agent attack-client --wait=false >/dev/null 2>&1 || true; rm -rf "$TMP"' EXIT

kubectl create configmap attack-client -n agent --from-file=scripts/attack_client.py \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
cat <<YAML | kubectl apply -f - >/dev/null
apiVersion: extensions.agents.x-k8s.io/v1beta1
kind: SandboxClaim
metadata: {name: $CLAIM, namespace: $NS}
spec:
  warmPoolRef: {name: $POOL}
YAML
kubectl wait -n $NS sandboxclaim/$CLAIM --for=condition=Ready --timeout=120s >/dev/null
SB=$(kubectl get sandboxclaim -n $NS $CLAIM -o jsonpath='{.status.sandbox.name}')
SB_IP=$(kubectl get pod -n $NS "$SB" -o jsonpath='{.status.podIP}')
OTHER_IP=$(kubectl get pod -n $NS -o jsonpath="{.items[?(@.metadata.name!='$SB')].status.podIP}" | awk '{print $1}')
API_IP=$(kubectl get svc kubernetes -n default -o jsonpath='{.spec.clusterIP}')
DNS_IP=$(kubectl get svc kube-dns -n kube-system -o jsonpath='{.spec.clusterIP}')
RESTARTS_BEFORE=$(kubectl get pod -n $NS "$SB" -o jsonpath='{.status.containerStatuses[0].restartCount}')
START=$(date -u +%Y-%m-%dT%H:%M:%SZ)
echo "sandbox $SB ($SB_IP); other sandbox $OTHER_IP"

# run_client PHASE -> appends the client's JSON lines to $TMP/results.jsonl
run_client() {
  kubectl delete pod -n agent attack-client --ignore-not-found --wait=true >/dev/null
  kubectl apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Pod
metadata: {name: attack-client, namespace: agent, labels: {app: agent}}
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  securityContext: {runAsNonRoot: true, runAsUser: 65534, seccompProfile: {type: RuntimeDefault}}
  containers:
  - name: client
    image: python:3.13-slim
    command: ["python", "/client/attack_client.py", "$1", "http://$SB_IP:8888", "$OTHER_IP", "$API_IP", "$DNS_IP"]
    securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: ["ALL"]}}
    volumeMounts: [{name: client, mountPath: /client}]
  volumes: [{name: client, configMap: {name: attack-client}}]
YAML
  kubectl wait -n agent pod/attack-client --for=jsonpath='{.status.phase}'=Succeeded --timeout=400s >/dev/null
  kubectl logs -n agent attack-client >> "$TMP/results.jsonl"
}
restarts() { kubectl get pod -n $NS "$SB" -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || echo gone; }

echo "phase 1: attacks the sandbox must survive"
run_client main
sleep 3
RESTARTS_AFTER=$(restarts)
echo "phase 2: multi-process memory bomb (must be contained to this sandbox)"
run_client crash
sleep 5
RESTARTS_CRASH=$(restarts)
NODE_READY=$(kubectl get node -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}')
kubectl -n kube-system exec ds/cilium -c cilium-agent -- \
  hubble observe --ip "$SB_IP" --verdict DROPPED --since "$START" -o json > "$TMP/drops.json" 2>/dev/null || true

python3 - "$TMP/results.jsonl" "$TMP/drops.json" "$REPORT" "$SB" "$RESTARTS_BEFORE" "$RESTARTS_AFTER" "$RESTARTS_CRASH" "$NODE_READY" "$RUNTIME" <<'EOF'
import json, sys, collections, datetime, subprocess
results_f, drops_f, report_f, sb, r_before, r_after, r_crash, node_ready, runtime = sys.argv[1:10]
results = {r["id"]: r for r in map(json.loads, open(results_f))}

# Hubble: summarise dropped flows from the sandbox by protocol and destination.
drops = collections.Counter()
for line in open(drops_f):
    try:
        f = json.loads(line)["flow"]
    except (ValueError, KeyError):
        continue
    l4, dst = f.get("l4", {}), f.get("IP", {}).get("destination", "?")
    if "TCP" in l4:   key = f"TCP {dst}:{l4['TCP']['destination_port']}"
    elif "UDP" in l4: key = f"UDP {dst}:{l4['UDP']['destination_port']}"
    elif "ICMPv4" in l4: key = f"ICMP {dst}"
    else: key = f"other {dst}"
    drops[key] += 1
def dropped(prefix):
    return sum(n for k, n in drops.items() if k.startswith(prefix))

def out(aid):
    r = results.get(aid, {}).get("result", {})
    text = (r.get("stdout", "") + r.get("stderr", "")).strip() or r.get("transport_error", "no result")
    lines = [l.strip() for l in text.splitlines() if l.strip()]
    # One line per table cell: for a traceback keep only the exception line.
    return lines[-1] if lines and lines[0].startswith("Traceback") else "; ".join(lines)

rows, failed = [], False
def judge(aid, ok, layer, observed):
    global failed
    healthy = results.get(aid, {}).get("healthy_after", False)
    verdict = "PASS" if ok and healthy else "FAIL"
    failed |= verdict == "FAIL"
    rows.append((verdict, aid, results.get(aid, {}).get("desc", aid), observed, layer, "yes" if healthy else "NO"))

kata = runtime == "kata"
kernel = "the guest kernel" if kata else "gVisor"
o = out("fork-bomb")
judge("fork-bomb", "fork failures" in o and not o.endswith("failures 0"),
      f"`RLIMIT_NPROC` (32) set by the executor, enforced by {kernel}; wall-clock timeout kills the process group. *Not* the pod pids cgroup: "
      + ("guest processes live in the VM, and the guest cgroup's `pids.max` is `max`." if kata else "gVisor guest processes aren't host tasks."), o)
o = out("memory-bomb")
judge("memory-bomb", o.startswith("MemoryError"),
      f"`RLIMIT_AS` (192 MiB per process) set by the executor, enforced by {kernel}. "
      + ("Without it, the guest's container cgroup (256 MiB) OOM-kills the process." if kata
         else "Without it the allocation goes past the 256 MiB pod limit and kills the whole sandbox (node swap must be off for that limit to be real)."), o)
o = out("credential-hunt")
judge("credential-hunt", "found: nothing" in o,
      "No SA token, no secrets in env, `enableServiceLinks: false`; cloud metadata unreachable (default-deny egress).", o)
o = out("persistence")
judge("persistence", "stopped" in o or "no beacon" in o,
      "Executor kills every process of the sandbox uid after each run (`kill(-1)`), not just the run's process group; `tini` as PID 1 reaps them.", o)
o = out("tcp-egress")
judge("tcp-egress", "CONNECTED" not in o and dropped("TCP") > 0,
      f"Default-deny egress NetworkPolicy, enforced by Cilium. Hubble: {dropped('TCP')} TCP packets dropped.", o)
o = out("dns-exfil")
judge("dns-exfil", "ANSWERED" not in o and dropped("UDP") > 0,
      f"Default-deny egress covers UDP/53 to both cluster and public DNS. Hubble: {dropped('UDP')} UDP packets dropped.", o)
o = out("icmp")
icmp_ok = "REPLY" not in o and o.startswith("raw socket denied")
judge("icmp", icmp_ok,
      f"Raw sockets: `CAP_NET_RAW` dropped. Unprivileged ICMP: default-deny egress (Hubble: {dropped('ICMP')} ICMP packets dropped).", o)

survived = r_before == r_after
crash = results.get("memory-bomb-multiprocess", {})
crashed = r_crash != r_after
crash_obs = out("memory-bomb-multiprocess")
# The limit must hold: the sandbox dies (gVisor), or processes are OOM-killed
# inside it (Kata). Never all 8 surviving with 64 MiB each.
oom_killed = "OOM-killed" in crash_obs and not crash_obs.startswith("8 of 8")
limit_held = crashed or oom_killed
contained = limit_held and crash.get("other_sandbox_healthy") is True and node_ready == "True"
failed |= not contained
failed |= not survived
now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
with open(report_f, "w") as f:
    f.write(f"""# Attack demos

Generated by `make attack-demos` on {now}. Each attack is ordinary code submitted to the sandbox executor by an agent-identity pod. The verdict needs the expected outcome **and** a working sandbox afterwards: a follow-up run that forks a process and prints `ok` must succeed, which also catches leftover processes or zombies eating the process cap.

Environment: kind on WSL2, {"Kata Containers with Cloud Hypervisor (`kata-clh`, guest seccomp on, `sandbox_cgroup_only`)" if kata else "gVisor (`runsc`)"}, Cilium eBPF-only datapath, node swap off for pods.

| Verdict | Attack | What the code observed | Stopped by | Sandbox OK after |
| --- | --- | --- | --- | --- |
""")
    for v, aid, desc, obs, layer, h in rows:
        obs = obs.replace("|", "\\|")[:300]
        f.write(f"| {v} | **{aid}**: {desc} | `{obs}` | {layer} | {h} |\n")
    f.write(f"\nSandbox `{sb}` container restarts during phase 1: {r_before} → {r_after} ({'none' if survived else 'RESTARTED'}).\n")
    f.write(f"""
## Backstop: memory spread across processes

| Verdict | Attack | What the agent saw | Contained by |
| --- | --- | --- | --- |
| {'CONTAINED' if contained else 'FAIL'} | **memory-bomb-multiprocess**: {crash.get('desc', '')} | `{crash_obs[:200]}` | {"The guest's container cgroup (256 MiB): the guest kernel OOM-kills some of the processes and the sandbox keeps running" if kata else "Pod memory limit (256 MiB, no swap). The per-process cap can't see the total, so the sandbox dies"} (restarts {r_after} → {r_crash}). Other sandbox still serving: {'yes' if crash.get('other_sandbox_healthy') else 'NO'}. Node Ready: {node_ready}. Blast radius: {"some of the task's own processes" if kata else "one disposable sandbox"}. |
""")
    f.write("\n## Hubble: dropped flows from the sandbox\n\n| Flow | Packets |\n| --- | --- |\n")
    for k, n in sorted(drops.items()):
        f.write(f"| {k} | {n} |\n")
for v, aid, desc, obs, layer, h in rows:
    print(f"{v}  {aid}: {obs[:110]}")
print(f"{'PASS' if survived else 'FAIL'}  sandbox restarts {r_before} -> {r_after}")
print(f"{'CONTAINED' if contained else 'FAIL'}  memory-bomb-multiprocess: {crash_obs[:60]} | sandbox restarts {r_after} -> {r_crash}, other sandbox ok={crash.get('other_sandbox_healthy')}, node Ready={node_ready}")
print(f"report: {report_f}")
sys.exit(1 if failed else 0)
EOF
