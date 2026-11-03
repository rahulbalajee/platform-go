# Packages a binary cross-compiled on the host into an empty image. Used by
# hack/e2e-kind.sh for a fast local loop (the approach ko takes); release
# images are built with the multi-stage Dockerfile at the repository root.
# The binary lands at /<name>; Pod specs set `command` explicitly.
FROM scratch
ARG BINARY
COPY ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY ${BINARY} /${BINARY}
USER 65532:65532
