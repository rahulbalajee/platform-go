# Packages the Chapter 5 demo programs, cross-compiled on the host with
# CGO_ENABLED=0 GOOS=linux, into an empty image. No base image is pulled.
# Each binary lands at /<name>; run one with `docker run pgo-ch05 /<name>`.
FROM scratch
COPY bin/ /
USER 65532:65532
