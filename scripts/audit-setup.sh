#!/usr/bin/env bash
# P4 milestone 2: turn on the API server's audit log (P4-04) and ship it
# to the audit sink. Run by `make audit` after the sink's image is loaded.
# Idempotent; ROTATE=1 issues new certificates.
#
# 1. Certificates for the API server -> sink link, from a CA made for it
#    alone: the sink's serving certificate (for its fixed ClusterIP) and
#    the API server's client certificate. The CA's key is discarded once
#    both are signed, so no one can issue another client certificate the
#    sink would accept; rotating means a new CA.
# 2. The sink: namespace, Secret, volume, Deployment, network policy.
# 3. The node: policy, webhook config and client certificate into
#    /etc/kubernetes/audit; the audit flags and mounts into the API
#    server's static pod (the original is kept as
#    /etc/kubernetes/audit/kube-apiserver.yaml.orig), and a wait for the
#    restarted API server.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
cd "$(dirname "$0")/.."
A=projects/04-observability/audit
NODE=${CLUSTER:-safe-ops}-control-plane
SINK_IP=10.96.0.200
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
node() { docker exec "$NODE" "$@"; }

kubectl apply -f $A/manifests/00-namespace.yaml

# 1. Certificates: new ones if asked, or if either end is missing its half.
have_secret=$(kubectl get secret -n audit audit-sink-tls -o name 2>/dev/null || true)
have_node=$(node sh -c 'test -s /etc/kubernetes/audit/client.crt && echo yes' || true)
if [ "${ROTATE:-}" = 1 ] || [ -z "$have_secret" ] || [ -z "$have_node" ]; then
  echo "issuing certificates"
  cd "$TMP"
  ec() { openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes "$@" 2>/dev/null; }
  ec -x509 -days 3650 -keyout ca.key -out ca.crt -subj /CN=safe-ops-audit-ca \
    -addext basicConstraints=critical,CA:TRUE -addext keyUsage=critical,keyCertSign
  sign() { # NAME CN EXTENSIONS
    ec -keyout "$1.key" -out "$1.csr" -subj "/CN=$2"
    printf "basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\n%s\n" "$3" > "$1.ext"
    openssl x509 -req -in "$1.csr" -CA ca.crt -CAkey ca.key -CAcreateserial -days 365 -out "$1.crt" -extfile "$1.ext" 2>/dev/null
  }
  sign tls audit-sink.audit.svc "extendedKeyUsage=serverAuth
subjectAltName=IP:$SINK_IP,DNS:audit-sink.audit.svc"
  sign client kube-apiserver-audit "extendedKeyUsage=clientAuth"
  shred -u ca.key 2>/dev/null || rm -f ca.key
  cd - >/dev/null
  kubectl create secret generic -n audit audit-sink-tls \
    --from-file=tls.crt=$TMP/tls.crt --from-file=tls.key=$TMP/tls.key --from-file=ca.crt=$TMP/ca.crt \
    --dry-run=client -o yaml | kubectl apply -f -
  node mkdir -p /etc/kubernetes/audit
  docker cp $TMP/ca.crt "$NODE":/etc/kubernetes/audit/ca.crt
  docker cp $TMP/client.crt "$NODE":/etc/kubernetes/audit/client.crt
  docker cp $TMP/client.key "$NODE":/etc/kubernetes/audit/client.key
  node sh -c 'chown root:root /etc/kubernetes/audit/*; chmod 600 /etc/kubernetes/audit/client.key; chmod 644 /etc/kubernetes/audit/*.crt'
fi

# 2. The sink.
kubectl apply -f $A/manifests/
kubectl -n audit rollout restart deploy/audit-sink
kubectl -n audit rollout status deploy/audit-sink --timeout=120s

# 3. The node and the API server.
docker cp $A/policy.yaml "$NODE":/etc/kubernetes/audit/policy.yaml
docker cp $A/webhook.kubeconfig "$NODE":/etc/kubernetes/audit/webhook.kubeconfig
node chmod 644 /etc/kubernetes/audit/policy.yaml /etc/kubernetes/audit/webhook.kubeconfig
# The hash covers the certificates too: the API server reads them at start.
hash=$(node sh -c 'cat /etc/kubernetes/audit/policy.yaml /etc/kubernetes/audit/webhook.kubeconfig /etc/kubernetes/audit/*.crt' | sha256sum | cut -c1-16)
docker cp "$NODE":/etc/kubernetes/manifests/kube-apiserver.yaml $TMP/current.yaml
python3 scripts/audit_apiserver.py "$hash" < $TMP/current.yaml > $TMP/new.yaml
if cmp -s $TMP/current.yaml $TMP/new.yaml; then
  echo "API server already has this audit configuration"
else
  echo "restarting the API server with audit configuration $hash"
  node sh -c 'test -e /etc/kubernetes/audit/kube-apiserver.yaml.orig || cp /etc/kubernetes/manifests/kube-apiserver.yaml /etc/kubernetes/audit/kube-apiserver.yaml.orig'
  # Staged outside the manifests directory, then moved in: the kubelet
  # reads every file there as a static pod.
  docker cp $TMP/new.yaml "$NODE":/etc/kubernetes/audit/kube-apiserver.yaml.new
  node mv /etc/kubernetes/audit/kube-apiserver.yaml.new /etc/kubernetes/manifests/kube-apiserver.yaml
  for i in $(seq 1 90); do
    got=$(kubectl get pod -n kube-system "kube-apiserver-$NODE" \
      -o jsonpath='{.metadata.annotations.safe-ops\.io/audit-config-hash} {.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
    [ "$got" = "$hash True" ] && break
    [ "$i" = 90 ] && { echo "the API server didn't come back with the new configuration; original in /etc/kubernetes/audit/kube-apiserver.yaml.orig on the node"; exit 1; }
    sleep 2
  done
  # Clients reconnect (the controller, the worker) on their own.
  kubectl wait --for=condition=Ready pod -n kube-system -l component=kube-apiserver --timeout=60s >/dev/null
  echo "API server restarted"
fi
node sh -c 'ls -l /var/log/kubernetes/audit/'
