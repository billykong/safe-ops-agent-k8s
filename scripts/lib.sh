# Sourced by the scripts here. Pin kubectl to this project's kind cluster, so
# a script never runs against whatever context another tool last switched to
# (kind create, for one, makes its new cluster current).
KUBE_CONTEXT=${KUBE_CONTEXT:-kind-${CLUSTER:-safe-ops}}
kubectl() { command kubectl --context "$KUBE_CONTEXT" "$@"; }
