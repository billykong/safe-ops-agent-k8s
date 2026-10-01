SANDBOX_VERSION ?= v1.0.4
CILIUM_VERSION  ?= 1.20.2
CLUSTER         ?= safe-ops
P1              := projects/01-sandboxed-code-exec

.PHONY: up down cilium agent-sandbox executor-test executor-image p1 verify test-executor

up:
	kind create cluster --config cluster/kind-gvisor.yaml
	$(MAKE) cilium
	$(MAKE) agent-sandbox

down:
	kind delete cluster --name $(CLUSTER)

cilium:
	helm repo add cilium https://helm.cilium.io >/dev/null 2>&1 || true
	helm upgrade --install cilium cilium/cilium --version $(CILIUM_VERSION) \
	  --namespace kube-system -f cluster/cilium-values.yaml --wait --timeout 10m
	kubectl wait --for=condition=Ready nodes --all --timeout=180s

agent-sandbox:
	kubectl apply --server-side -f https://github.com/kubernetes-sigs/agent-sandbox/releases/download/$(SANDBOX_VERSION)/sandbox-with-extensions.yaml
	kubectl -n agent-sandbox-system rollout status deploy --timeout=180s

executor-test:
	cd $(P1)/executor && python3 -m unittest test_executor.py

executor-image:
	docker build -t sandbox-executor:dev $(P1)/executor
	kind load docker-image sandbox-executor:dev --name $(CLUSTER)

p1: executor-image
	kubectl apply -f $(P1)/manifests/

verify:
	./scripts/verify-gvisor.sh

test-executor:
	./scripts/test-executor.sh
