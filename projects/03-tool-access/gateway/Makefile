# The agents' gateway. Cluster targets live in the repo's top-level Makefile.
IMG ?= agent-gateway:dev
CLUSTER ?= safe-ops

.PHONY: test build image kind-load
test:
	go vet ./... && go test ./... -count=1

build: test
	CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -o bin/gateway ./cmd/gateway

image: build
	docker build -t $(IMG) .

kind-load: image
	kind load docker-image $(IMG) --name $(CLUSTER)
