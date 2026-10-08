# Built on the host (`make build`, static, CGO off) and copied in, like the
# approval controller (P1 README finding 29: large pulls are unreliable here).
FROM gcr.io/distroless/static:nonroot
COPY bin/gateway /gateway
USER 65532:65532
ENTRYPOINT ["/gateway"]
