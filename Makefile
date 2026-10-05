SANDBOX_VERSION ?= v1.0.4
CILIUM_VERSION  ?= 1.20.2
KATA_VERSION    ?= 4.2.0
CLUSTER         ?= safe-ops
CLIENT_IMAGE    := python:3.13-slim
P1              := projects/01-sandboxed-code-exec
# Always target this cluster, never whatever context is current: creating
# another kind cluster switches the current context to it.
KUBECTL         := kubectl --context kind-$(CLUSTER)
export CLUSTER

.PHONY: client-image up down node-swap-off cilium coredns-upstream agent-sandbox executor-test executor-image agent-image p1 verify test-executor test-agent attack-demos bench test-egress kata verify-kata attack-demos-kata test-pod-security

up:
	# kind makes a new cluster's context current, which retargets every bare
	# kubectl of other projects and sessions (finding 17 in the P1 README).
	# Write its kubeconfig to a separate file, then merge it in without
	# touching current-context (the first file in KUBECONFIG wins).
	set -e; tmp=$$(mktemp -d); trap 'rm -rf $$tmp' EXIT; mkdir -p $$HOME/.kube; touch $$HOME/.kube/config; \
	kind create cluster --config cluster/kind-gvisor.yaml --kubeconfig $$tmp/kind; \
	for k in context cluster user; do kubectl config delete-$$k kind-$(CLUSTER) >/dev/null 2>&1 || true; done; \
	KUBECONFIG=$$HOME/.kube/config:$$tmp/kind kubectl config view --flatten > $$tmp/merged; \
	install -m 600 $$tmp/merged $$HOME/.kube/config
	$(MAKE) node-swap-off
	$(MAKE) cilium
	$(MAKE) coredns-upstream
	$(MAKE) agent-sandbox

down:
	kind delete cluster --name $(CLUSTER)

# Pods must not swap: with host swap available (WSL2 defaults to some), a
# pod's memory limit isn't a hard cap and a memory bomb thrashes the node.
# kubelet's NoSwap only covers container cgroups; gVisor's memory is charged
# at the pod level, so cap swap on the whole kubelet.slice instead.
node-swap-off:
	docker exec $(CLUSTER)-control-plane sh -c '\
	  mkdir -p /etc/systemd/system/kubelet.slice.d && \
	  printf "[Slice]\nMemorySwapMax=0\n" > /etc/systemd/system/kubelet.slice.d/10-no-swap.conf && \
	  systemctl daemon-reload && systemctl set-property --runtime kubelet.slice MemorySwapMax=0 && \
	  echo "kubelet.slice memory.swap.max=$$(cat /sys/fs/cgroup/kubelet.slice/memory.swap.max)"'

cilium:
	helm repo add cilium https://helm.cilium.io >/dev/null 2>&1 || true
	helm upgrade --install cilium cilium/cilium --version $(CILIUM_VERSION) \
	  --kube-context kind-$(CLUSTER) --namespace kube-system -f cluster/cilium-values.yaml --wait --timeout 10m
	# Agents read their config at start; a changed value needs a restart.
	$(KUBECTL) -n kube-system rollout restart ds/cilium deploy/cilium-operator
	$(KUBECTL) -n kube-system rollout status ds/cilium --timeout=180s
	$(KUBECTL) wait --for=condition=Ready nodes --all --timeout=180s

# kind points the node's resolver at an address that the node's iptables
# DNAT to Docker's embedded DNS. Cilium's eBPF host routing skips the node's
# iptables, so CoreDNS's forwarded queries never reach it and every external
# name fails. Forward to explicit public resolvers instead.
coredns-upstream:
	$(KUBECTL) -n kube-system get cm coredns -o yaml \
	  | sed 's|forward \. /etc/resolv.conf|forward . 1.1.1.1 8.8.8.8|' | $(KUBECTL) apply -f -
	$(KUBECTL) -n kube-system rollout restart deploy/coredns
	$(KUBECTL) -n kube-system rollout status deploy/coredns --timeout=120s

agent-sandbox:
	$(KUBECTL) apply --server-side -f https://github.com/kubernetes-sigs/agent-sandbox/releases/download/$(SANDBOX_VERSION)/sandbox-with-extensions.yaml
	$(KUBECTL) -n agent-sandbox-system rollout status deploy --timeout=180s

executor-test:
	cd $(P1)/executor && python3 -m unittest test_executor.py

executor-image:
	docker build -t sandbox-executor:dev $(P1)/executor
	kind load docker-image sandbox-executor:dev --name $(CLUSTER)

agent-image:
	docker build -t sandbox-agent:dev $(P1)/agent
	kind load docker-image sandbox-agent:dev --name $(CLUSTER)

# Third-party images go into the node through scripts/fetch_image.py, not
# the node's own pulls: large layers kept failing with resets and stalls from
# a NAT on the path, and containerd restarts a failed layer from zero. The
# script resumes each blob with HTTP Range requests, verifies its sha256,
# caches it across rebuilds, and imports only this platform's manifest.
define preload
	python3 scripts/fetch_image.py $(1) --node $(CLUSTER)-control-plane
endef

# The test clients (agent-identity pods in the scripts) run this image.
client-image:
	$(call preload,$(CLIENT_IMAGE))

p1: executor-image agent-image client-image
	$(KUBECTL) apply -f $(P1)/manifests/

verify:
	./scripts/verify-sandbox.sh gvisor

verify-kata:
	./scripts/verify-sandbox.sh kata

test-executor:
	./scripts/test-executor.sh

test-agent:
	./scripts/test-agent.sh

test-pod-security:
	./scripts/test-pod-security.sh

attack-demos:
	./scripts/attack-demos.sh gvisor

attack-demos-kata:
	./scripts/attack-demos.sh kata

bench:
	./scripts/bench.sh

test-egress:
	./scripts/test-egress.sh

# Optional: Kata Containers (RuntimeClass kata-clh) plus a python-kata
# template and warm pool, for the runtime comparison. Run after `make p1`;
# not part of `make up`.
kata:
	$(call preload,quay.io/kata-containers/kata-deploy:$(KATA_VERSION))
	helm upgrade --install kata-deploy --kube-context kind-$(CLUSTER) -n kube-system \
	  https://github.com/kata-containers/kata-containers/releases/download/$(KATA_VERSION)/kata-deploy-$(KATA_VERSION).tgz \
	  -f cluster/kata-values.yaml --wait --timeout 15m
	$(KUBECTL) -n kube-system rollout status ds/kata-deploy --timeout=15m
	$(KUBECTL) apply -f $(P1)/manifests/kata/
