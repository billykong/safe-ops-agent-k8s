#!/usr/bin/env bash
# Issue a client certificate for a human approver (CN=<name>,
# O=safe-ops:approvers) through the cluster's CSR API, and write a
# standalone kubeconfig for it. The private key is generated here and never
# leaves this machine; the cluster only signs the request. Your main
# kubeconfig and current context are untouched.
#
# Usage: scripts/new-approver.sh NAME [OUT_KUBECONFIG] [DAYS]
#   default OUT: ~/.kube/safe-ops-approver-NAME.kubeconfig, DAYS: 30
set -euo pipefail
source "$(dirname "$0")/lib.sh"
NAME=${1:?usage: new-approver.sh NAME [OUT_KUBECONFIG] [DAYS]}
OUT=${2:-$HOME/.kube/safe-ops-approver-$NAME.kubeconfig}
DAYS=${3:-30}
case $NAME in system:*|*/*) echo "invalid approver name: $NAME" >&2; exit 2 ;; esac
CSR=approver-$NAME-$(date +%s)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"; kubectl delete csr "$CSR" --ignore-not-found >/dev/null 2>&1 || true' EXIT
umask 077

openssl req -new -newkey rsa:3072 -nodes -keyout "$tmp/key.pem" -out "$tmp/req.pem" \
  -subj "/CN=$NAME/O=safe-ops:approvers" 2>/dev/null
kubectl apply -f - >/dev/null <<YAML
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata: {name: $CSR}
spec:
  request: $(base64 -w0 < "$tmp/req.pem")
  signerName: kubernetes.io/kube-apiserver-client
  expirationSeconds: $(( DAYS * 86400 ))
  usages: [client auth]
YAML
kubectl certificate approve "$CSR" >/dev/null
for _ in $(seq 1 30); do
  cert=$(kubectl get csr "$CSR" -o jsonpath='{.status.certificate}')
  [ -n "$cert" ] && break; sleep 1
done
[ -n "$cert" ] || { echo "certificate not issued" >&2; exit 1; }
base64 -d <<<"$cert" > "$tmp/cert.pem"
# Delete the CSR now, while kubectl still points at the cluster admin's
# context (KUBECONFIG is switched to the new file below). Deleting it doesn't
# revoke the certificate: its validity period does that.
kubectl delete csr "$CSR" >/dev/null

server=$(kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.server}')
kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d > "$tmp/ca.pem"
mkdir -p "$(dirname "$OUT")"
export KUBECONFIG=$OUT
rm -f "$OUT"
command kubectl config set-cluster safe-ops --server="$server" --certificate-authority="$tmp/ca.pem" --embed-certs >/dev/null
command kubectl config set-credentials "$NAME" --client-certificate="$tmp/cert.pem" --client-key="$tmp/key.pem" --embed-certs >/dev/null
command kubectl config set-context "approver-$NAME" --cluster=safe-ops --user="$NAME" --namespace=approvals >/dev/null
command kubectl config use-context "approver-$NAME" >/dev/null
chmod 600 "$OUT"
echo "approver $NAME: $OUT (valid $DAYS days)"
command kubectl auth whoami
