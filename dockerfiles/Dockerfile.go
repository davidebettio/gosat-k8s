# Multi-stage Dockerfile for gosat-server (Go).
# Supports cross-compilation via --platform flag.
#
# Usage:
#   docker build --platform linux/arm64 -f gosat-k8s/dockerfiles/Dockerfile.go \
#     -t gosat-server:latest gosat-server/

ARG GO_VERSION=1.26

# ─── Stage 1: build ──────────────────────────────────────────────────────────
FROM --platform=$BUILDPLATFORM golang:${GO_VERSION}-alpine AS builder
ARG TARGETARCH
RUN apk add --no-cache git
WORKDIR /app

COPY go.mod go.sum ./
RUN go mod download

COPY *.go ./
COPY log ./log
RUN CGO_ENABLED=0 GOOS=linux GOARCH=${TARGETARCH} go build -ldflags="-s -w" -o gosat-server .

# ─── Stage 2: minimal runtime ────────────────────────────────────────────────
FROM alpine:3.20
RUN apk add --no-cache ca-certificates tzdata
WORKDIR /app

COPY --from=builder /app/gosat-server .

EXPOSE 30060
USER nobody
ENTRYPOINT ["./gosat-server"]
