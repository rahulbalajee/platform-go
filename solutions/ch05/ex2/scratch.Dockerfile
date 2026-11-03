# An empty image for the Linux builds of this chapter's programs. No base
# image is pulled. Build the binaries, then the image, from the module root:
#   CGO_ENABLED=0 GOOS=linux go build -o linux/ ./cmd/...
#   docker build -q -f scratch.Dockerfile -t oskit linux
# and run one with `docker run --rm oskit /<name>`.
FROM scratch
COPY . /
USER 65532:65532
