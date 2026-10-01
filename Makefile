SANDBOX_VERSION ?= v1.0.4
CLUSTER         ?= safe-ops
P1              := projects/01-sandboxed-code-exec

.PHONY: up down agent-sandbox p1 verify

up:
	kind create cluster --config cluster/kind-gvisor.yaml
	$(MAKE) agent-sandbox

down:
	kind delete cluster --name $(CLUSTER)

agent-sandbox:
	kubectl apply --server-side -f https://github.com/kubernetes-sigs/agent-sandbox/releases/download/$(SANDBOX_VERSION)/sandbox-with-extensions.yaml
	kubectl -n agent-sandbox-system rollout status deploy --timeout=180s

p1:
	kubectl apply -f $(P1)/manifests/

verify:
	./scripts/verify-gvisor.sh
