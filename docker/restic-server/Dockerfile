# restic REST server built from the tagged upstream source with a CURRENT Go toolchain and refreshed golang.org/x
# modules. Upstream's last release (0.14.0, May 2025) ships an image built with an old Go whose standard library has
# since had critical fixes, and the project publishes no newer image, so we build it ourselves.
# Bump REST_VERSION when upstream releases; bump GO_IMAGE for Go security releases; re-scan after each build.
ARG GO_IMAGE=golang:1.26-alpine3.24
ARG RUNTIME_IMAGE=alpine:3.24

FROM ${GO_IMAGE} AS build
ARG REST_VERSION=0.14.0
RUN apk add --no-cache git
RUN git clone --quiet --depth 1 --branch "v${REST_VERSION}" https://github.com/restic/rest-server /src
WORKDIR /src
RUN go get golang.org/x/crypto@latest golang.org/x/net@latest golang.org/x/text@latest golang.org/x/sys@latest \
 && go mod tidy \
 && CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o /out/rest-server ./cmd/rest-server \
 && go version -m /out/rest-server | grep -E "^/out|go1|golang.org/x/(crypto|net|text|sys)" 

FROM ${RUNTIME_IMAGE}
COPY --from=build /out/rest-server /usr/local/bin/rest-server
USER 1500:3002
ENTRYPOINT ["/usr/local/bin/rest-server"]
