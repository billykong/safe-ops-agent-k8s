SANDBOX_VERSION ?= v1.0.4
CILIUM_VERSION  ?= 1.20.2
KATA_VERSION    ?= 4.2.0
CLUSTER         ?= safe-ops
CLIENT_IMAGE    := python:3.13-slim
P1              := projects/01-sandboxed-code-exec
P2              := projects/02-approval-gate
# Go for the P2 controller, installed by scripts/setup-go.sh (no sudo).
export PATH     := $(HOME)/.local/go/bin:$(PATH)
# Always target this cluster, never whatever context is current: creating
# another kind cluster switches the current context to it.
KUBECTL         := kubectl --context kind-$(CLUSTER)
export CLUSTER

.PHONY: client-image up down node-gvisor-platform node-swap-off cilium coredns-upstream agent-sandbox executor-test executor-image agent-image p1 verify test-executor test-agent attack-demos bench test-egress kata verify-kata attack-demos-kata test-pod-security p2 test-approval test-agent-guard test-budget test-kill-switch durable test-durable test-review p3 test-identity test-llm-gateway test-mcp test-policy red-team p4 test-observability audit test-audit evals test-evals ci-stack eval-gate test-eval-gate eval-kill-switch test-oversight p5 model-server-down test-local-model test-gpu test-serving test-gpu-metrics

up:
	# kind makes a new cluster's context current, which retargets every bare
	# kubectl of other projects and sessions (finding 17 in the P1 README).
	# Write its kubeconfig to a separate file, then merge it in without
	# touching current-context (the first file in KUBECONFIG wins).
	set -e; tmp=$$(mktemp -d); trap 'rm -rf $$tmp' EXIT; mkdir -p $$HOME/.kube; touch $$HOME/.kube/config; \
	kind create cluster --name $(CLUSTER) --config cluster/kind-gvisor.yaml --kubeconfig $$tmp/kind; \
	for k in context cluster user; do kubectl config delete-$$k kind-$(CLUSTER) >/dev/null 2>&1 || true; done; \
	KUBECONFIG=$$HOME/.kube/config:$$tmp/kind kubectl config view --flatten > $$tmp/merged; \
	install -m 600 $$tmp/merged $$HOME/.kube/config
	$(MAKE) node-swap-off
	$(MAKE) node-gvisor-platform
	$(MAKE) cilium
	$(MAKE) coredns-upstream
	$(MAKE) agent-sandbox

down:
	kind delete cluster --name $(CLUSTER)

# Pods must not swap: with host swap available (WSL2 defaults to some), a
# pod's memory limit isn't a hard cap and a memory bomb thrashes the node.
# kubelet's NoSwap only covers container cgroups; gVisor's memory is charged
# at the pod level, so cap swap on the whole kubelet.slice instead.
# gVisor's platform (cluster/runsc.toml): copy the settings into the node
# and, on a cluster created before they existed, point containerd's runsc
# runtime at them. Idempotent; restarts containerd only when its config
# changes (running containers keep running).
node-gvisor-platform:
	docker cp cluster/runsc.toml $(CLUSTER)-control-plane:/etc/containerd/runsc.toml
	docker exec $(CLUSTER)-control-plane sh -c '\
	  grep -q "runtimes.runsc.options" /etc/containerd/config.toml || { \
	    sed -i "/runtimes.runsc\]/{n;s|\$$|\n        [plugins.\"io.containerd.grpc.v1.cri\".containerd.runtimes.runsc.options]\n          TypeUrl = \"io.containerd.runsc.v1.options\"\n          ConfigPath = \"/etc/containerd/runsc.toml\"|}" /etc/containerd/config.toml && \
	    systemctl restart containerd; }; \
	  grep -A3 "runtimes.runsc.options" /etc/containerd/config.toml'

node-swap-off:
	docker exec $(CLUSTER)-control-plane sh -c '\
	  mkdir -p /etc/systemd/system/kubelet.slice.d && \
	  printf "[Slice]\nMemorySwapMax=0\n" > /etc/systemd/system/kubelet.slice.d/10-no-swap.conf && \
	  systemctl daemon-reload && systemctl set-property --runtime kubelet.slice MemorySwapMax=0 && \
	  echo "kubelet.slice memory.swap.max=$$(cat /sys/fs/cgroup/kubelet.slice/memory.swap.max)"'

cilium:
	helm repo add cilium https://helm.cilium.io >/dev/null 2>&1 || true
	helm upgrade --install cilium cilium/cilium --version $(CILIUM_VERSION) \
	  --kube-context kind-$(CLUSTER) --namespace kube-system -f cluster/cilium-values.yaml \
	  --set k8sServiceHost=$(CLUSTER)-control-plane --wait --timeout 10m
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

# P2: ChangeRequest CRD, approval controller, agent's proposer role, demo
# workload. Builds the controller on the host and loads it into kind.
p2:
	$(MAKE) -C $(P2) kind-load cli CLUSTER=$(CLUSTER)
	$(KUBECTL) apply -f $(P2)/manifests/00-namespaces.yaml
	# The kill switch flag: created (mode run) only if missing, never
	# overwritten, so re-deploying can't un-stop a stopped agent.
	$(KUBECTL) get configmap -n approval-system agent-kill-switch >/dev/null 2>&1 || \
	  $(KUBECTL) create configmap -n approval-system agent-kill-switch --from-literal=mode=run --from-literal=reason="initial deploy"
	# The semantic action gate's policy, from git (tests excluded).
	$(KUBECTL) create configmap -n approval-system approval-policy --from-file=gate.rego=$(P2)/policy/gate.rego \
	  --dry-run=client -o yaml | $(KUBECTL) apply -f -
	$(KUBECTL) apply -f $(P2)/config/crd/bases/ -f $(P2)/config/rbac/role.yaml -f $(P2)/manifests/
	$(KUBECTL) -n approval-system rollout restart deploy/approval-controller
	$(KUBECTL) -n approval-system rollout status deploy/approval-controller --timeout=120s

test-approval:
	./scripts/test-approval.sh

test-agent-guard:
	./scripts/test-agent-guard.sh

# P2 milestone 5: Temporal and the agent as a Temporal worker.
DURABLE := $(P2)/durable
durable:
	$(call preload,temporalio/temporal:1.9.1)
	docker build -t approval-agent:dev $(DURABLE)/agent
	kind load docker-image approval-agent:dev --name $(CLUSTER)
	$(KUBECTL) apply -f $(DURABLE)/manifests/00-namespace.yaml
	$(KUBECTL) apply -f $(DURABLE)/manifests/
	$(KUBECTL) -n agent rollout restart deploy/agent-worker
	$(KUBECTL) -n temporal rollout status deploy/temporal --timeout=180s
	$(KUBECTL) -n agent rollout status deploy/agent-worker --timeout=180s

test-durable:
	./scripts/test-durable.sh

test-review:
	./scripts/test-review.sh

# P3: the agents' gateway (milestone 1: workload-identity authentication).
P3 := projects/03-tool-access
p3:
	$(MAKE) -C $(P3)/gateway kind-load CLUSTER=$(CLUSTER)
	$(KUBECTL) apply -f $(P3)/manifests/00-namespace.yaml
	# The mock provider's key: random, created once. A real key goes in
	# Secret anthropic-api-key, created by you (scripts/llm-gateway-mode.sh).
	$(KUBECTL) get secret -n gateways mock-provider-key >/dev/null 2>&1 || \
	  $(KUBECTL) create secret generic -n gateways mock-provider-key --from-literal=api-key=mock-$$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')
	docker build -t mcp-tools:dev $(P3)/mcp
	kind load docker-image mcp-tools:dev --name $(CLUSTER)
	$(KUBECTL) apply -f $(P3)/manifests/50-mcp-servers.yaml
	# The incident tracker's API token: random, created once, in the two
	# namespaces that hold it (the tracker checks it; the MCP gateway adds
	# it to tool calls). The agents never get it.
	$(KUBECTL) get secret -n mcp-servers incident-tracker-token >/dev/null 2>&1 || { \
	  t=$$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n'); \
	  $(KUBECTL) create secret generic -n mcp-servers incident-tracker-token --from-literal=token=$$t && \
	  $(KUBECTL) create secret generic -n gateways incident-tracker-token --from-literal=token=$$t; }
	$(KUBECTL) apply -f $(P3)/manifests/
	$(KUBECTL) -n gateways rollout restart deploy/llm-gateway deploy/mock-model deploy/mcp-gateway
	$(KUBECTL) -n mcp-servers rollout restart deploy/incidents-mcp deploy/incident-tracker deploy/netdiag-mcp
	$(KUBECTL) -n gateways rollout status deploy/llm-gateway --timeout=120s
	$(KUBECTL) -n gateways rollout status deploy/mock-model --timeout=120s
	$(KUBECTL) -n gateways rollout status deploy/mcp-gateway --timeout=120s
	$(KUBECTL) -n mcp-servers rollout status deploy/incidents-mcp --timeout=120s
	$(KUBECTL) -n mcp-servers rollout status deploy/netdiag-mcp --timeout=120s

test-identity:
	./scripts/test-identity.sh

test-llm-gateway:
	./scripts/test-llm-gateway.sh

test-mcp:
	./scripts/test-mcp.sh

test-policy:
	./scripts/test-policy.sh

# P3 milestone 5: the prompt-injection red-team (docs/red-team.md).
red-team:
	./scripts/red-team.sh

test-budget:
	./scripts/test-budget.sh

test-kill-switch:
	./scripts/test-kill-switch.sh

# P4 milestone 1: telemetry. The collector, Jaeger, Prometheus and Grafana
# in namespace observability; the agent, gateways and controller send to
# the collector once their own targets (durable, p3, p2) are redeployed.
P4 := projects/04-observability
OTELCOL_VERSION    ?= 0.161.0
JAEGER_VERSION     ?= 2.20.0
PROMETHEUS_VERSION ?= v3.13.3
GRAFANA_VERSION    ?= 13.2.2
p4:
	$(call preload,otel/opentelemetry-collector-k8s:$(OTELCOL_VERSION))
	$(call preload,jaegertracing/jaeger:$(JAEGER_VERSION))
	$(call preload,prom/prometheus:$(PROMETHEUS_VERSION))
	$(call preload,grafana/grafana:$(GRAFANA_VERSION))
	$(KUBECTL) apply -f $(P4)/manifests/00-namespace.yaml
	# Grafana's admin password: random, created once (viewing needs none).
	$(KUBECTL) get secret -n observability grafana-admin >/dev/null 2>&1 || \
	  $(KUBECTL) create secret generic -n observability grafana-admin --from-literal=password=$$(head -c 18 /dev/urandom | od -An -tx1 | tr -d ' \n')
	# The dashboards, from git.
	$(KUBECTL) create configmap -n observability grafana-dashboards --from-file=$(P4)/dashboards/ \
	  --dry-run=client -o yaml | $(KUBECTL) apply -f -
	$(KUBECTL) apply -f $(P4)/manifests/
	$(KUBECTL) -n observability rollout restart deploy/otel-collector deploy/jaeger deploy/prometheus deploy/grafana
	for d in otel-collector jaeger prometheus grafana; do $(KUBECTL) -n observability rollout status deploy/$$d --timeout=180s || exit 1; done

test-observability:
	./scripts/test-observability.sh

# P4 milestone 2: the API server's audit log (P4-04), to the audit sink in
# namespace audit and to a file on the node. Restarts the API server when
# the audit configuration changes. Run after `make p4` (Prometheus's
# alerts read the sink).
audit:
	$(MAKE) -C $(P4)/audit-sink kind-load CLUSTER=$(CLUSTER)
	./scripts/audit-setup.sh

test-audit:
	./scripts/test-audit.sh

# P4 milestone 3: the replay eval suite (P4-10..12). The runner image, the
# EvalRun CRD, namespaces evals and eval-sandbox, the evaluator's RBAC and
# the verdict-authority policy. Needs `make durable p3` for the agent's
# decision query and the gateway's evaluator identity.
evals:
	docker build -t eval-runner:dev $(P4)/evals/runner
	kind load docker-image eval-runner:dev --name $(CLUSTER)
	$(KUBECTL) apply -f $(P4)/evals/crd/
	$(KUBECTL) wait --for=condition=Established crd/evalruns.evals.safe-ops.io --timeout=60s
	$(KUBECTL) apply -f $(P4)/evals/manifests/

test-evals:
	./scripts/test-evals.sh

# P4 milestone 4: the eval regression gate (P4-13). eval-gate runs the
# replay evals and compares them with the baseline in git; CI
# (.github/workflows/eval-gate.yml) runs ci-stack then eval-gate on a fresh
# cluster: just what the evals need, in mock mode.
# The agent's namespace and identities come from P1's manifests; CI skips
# P1's sandboxes (images, warm pools), which the evals don't use.
ci-stack: up
	$(KUBECTL) apply -f $(P1)/manifests/10-namespace.yaml -f $(P1)/manifests/50-agent-namespace.yaml \
	  -f $(P1)/manifests/51-agent-rbac.yaml -f $(P1)/manifests/52-agent-networkpolicy.yaml \
	  -f $(P1)/manifests/53-claim-admission-policy.yaml
	$(MAKE) p2 durable p3 evals

eval-gate:
	./scripts/eval-gate.sh

test-eval-gate:
	./scripts/test-eval-gate.sh

# P4 milestone 5: the kill-switch drill (P4-14), run in the eval suite after
# the gate (CI too): stops the agent mid-work, checks every layer, resumes it
# and runs the gate again. test-oversight checks the drill and the oversight
# and quality metrics (P4-20..22); it needs `make p4` too.
eval-kill-switch:
	./scripts/eval-kill-switch.sh

test-oversight:
	./scripts/test-oversight.sh

# P5: a local model on the GPU, reached through the LLM gateway only. In the
# cluster (milestone 2): the WSL GPU driver and the CDI hook into the node,
# the NVIDIA device plugin (time-sliced in two), then vLLM as a restricted
# pod in namespace inference. Behind it (milestone 3): the serving stack,
# an InferencePool with llm-d's endpoint picker behind an agentgateway
# Gateway, and KEDA scaling vLLM from 1 to 2 on queue depth. Outside the
# cluster (milestone 1, the fallback): vLLM in Docker on a network only the
# node joins. One at a time (4 GB): `scripts/local-model-mode.sh
# cluster|docker`. model-server-down frees the GPU from the Docker server.
P5 := projects/05-local-inference

p5:
	./scripts/node-gpu.sh
	./scripts/device-plugin.sh
	# The server's image (15 GB; 35 minutes to load): built once, loaded
	# once. Not left to kind's own check: with Docker's containerd image
	# store, docker's image ID (the manifest's digest) never equals the
	# node's (the config's), so kind loads it again every time. A rebuilt
	# image needs a new tag.
	docker image inspect safe-ops-vllm:0.30.0-cu129 >/dev/null 2>&1 || docker build -t safe-ops-vllm:0.30.0-cu129 $(P5)/server
	docker exec $(CLUSTER)-control-plane crictl inspecti safe-ops-vllm:0.30.0-cu129 >/dev/null 2>&1 || \
	  kind load docker-image safe-ops-vllm:0.30.0-cu129 --name $(CLUSTER)
	$(KUBECTL) apply -f $(P5)/manifests/
	# Milestone 3 replaced the server's Service with the pool, and the
	# gateway's way in with the inference gateway's.
	$(KUBECTL) -n inference delete service local-model --ignore-not-found
	$(KUBECTL) -n inference delete networkpolicy local-model-from-gateway --ignore-not-found
	./scripts/serving-stack.sh
	# The gateway mounts the server's key (Secret local-model-key, optional).
	./scripts/model-server.sh key
	$(KUBECTL) -n gateways rollout restart deploy/llm-gateway
	$(KUBECTL) -n gateways rollout status deploy/llm-gateway --timeout=120s
	./scripts/local-model-mode.sh cluster

model-server-down:
	./scripts/model-server.sh down

test-local-model:
	./scripts/test-local-model.sh

test-gpu:
	./scripts/test-gpu.sh

test-serving:
	./scripts/test-serving.sh

test-gpu-metrics:
	./scripts/test-gpu-metrics.sh
