# Built on the host (`make build`, static, CGO off) and copied in, like the
# gateways and the approval controller.
FROM gcr.io/distroless/static:nonroot
COPY bin/audit-sink /audit-sink
USER 65532:65532
ENTRYPOINT ["/audit-sink"]
