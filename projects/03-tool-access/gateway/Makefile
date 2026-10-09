# The agents' gateway. Cluster targets live in the repo's top-level Makefile.
IMG ?= agent-gateway:dev
MOCK_IMG ?= mock-model:dev
MCPGW_IMG ?= mcp-gateway:dev
CLUSTER ?= safe-ops

.PHONY: test build image kind-load
test:
	go vet ./... && go test ./... -count=1

build: test
	CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -o bin/gateway ./cmd/gateway
	CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -o bin/mockmodel ./cmd/mockmodel
	CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -o bin/mcpgateway ./cmd/mcpgateway

image: build
	docker build -t $(IMG) .
	docker build -t $(MOCK_IMG) -f Dockerfile.mock .
	docker build -t $(MCPGW_IMG) -f Dockerfile.mcp .

kind-load: image
	kind load docker-image $(IMG) $(MOCK_IMG) $(MCPGW_IMG) --name $(CLUSTER)
