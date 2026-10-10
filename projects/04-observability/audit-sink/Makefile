# The audit sink. Cluster targets live in the repo's top-level Makefile.
IMG ?= audit-sink:dev
CLUSTER ?= safe-ops

.PHONY: test build image kind-load
test:
	go vet ./... && go test ./... -count=1

build: test
	CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -o bin/audit-sink ./cmd/audit-sink

image: build
	docker build -t $(IMG) .

kind-load: image
	kind load docker-image $(IMG) --name $(CLUSTER)
