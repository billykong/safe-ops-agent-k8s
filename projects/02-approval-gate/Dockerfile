# The manager is built on the host (`make build`, static, CGO off) and copied
# in, instead of compiling inside a ~800 MB Go builder image: large image
# pulls are unreliable on this network (P1 README finding 29).
FROM gcr.io/distroless/static:nonroot
COPY bin/manager /manager
USER 65532:65532
ENTRYPOINT ["/manager"]
