# Approval gate controller (kubebuilder layout). Cluster-wide targets live in
# the repo's top-level Makefile (`make p2`, `make test-approval`).
IMG ?= approval-controller:dev
CLUSTER ?= safe-ops
LOCALBIN ?= $(shell pwd)/bin
CONTROLLER_GEN ?= $(LOCALBIN)/controller-gen
CONTROLLER_TOOLS_VERSION ?= v0.22.0

.PHONY: all manifests generate fmt vet test build docker-build kind-load
all: build

# CRD and the controller's RBAC, generated from the markers in api/ and
# internal/controller/.
manifests: controller-gen
	"$(CONTROLLER_GEN)" rbac:roleName=approval-controller crd paths="./..." output:crd:artifacts:config=config/crd/bases

generate: controller-gen
	"$(CONTROLLER_GEN)" object:headerFile="hack/boilerplate.go.txt" paths="./..."

fmt:
	go fmt ./...

vet:
	go vet ./...

test: manifests generate fmt vet
	go test ./... -count=1

build: manifests generate fmt vet
	CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -o bin/manager cmd/main.go

docker-build: build
	docker build -t $(IMG) .

kind-load: docker-build
	kind load docker-image $(IMG) --name $(CLUSTER)

controller-gen: $(CONTROLLER_GEN)
$(CONTROLLER_GEN):
	mkdir -p $(LOCALBIN)
	GOBIN=$(LOCALBIN) go install sigs.k8s.io/controller-tools/cmd/controller-gen@$(CONTROLLER_TOOLS_VERSION)
