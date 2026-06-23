# syntax=docker/dockerfile:1
ARG ALPINE_VERSION=3.22

FROM --platform=$BUILDPLATFORM alpine:${ALPINE_VERSION} AS builder

# Install dependencies needed to download and extract Zig
RUN apk add --no-cache curl xz ca-certificates

# Define the build architecture and download the corresponding Zig compiler
ARG BUILDARCH
ARG ZIG_VERSION=0.16.0
RUN set -eu; \
    case "$BUILDARCH" in \
      amd64) ZIG_ARCH="x86_64" ;; \
      arm64) ZIG_ARCH="aarch64" ;; \
      *) echo "unsupported Docker build host architecture: $BUILDARCH" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-${ZIG_ARCH}-linux-${ZIG_VERSION}.tar.xz" -o zig.tar.xz && \
    tar -xf zig.tar.xz && \
    mv "zig-${ZIG_ARCH}-linux-${ZIG_VERSION}" /opt/zig

ENV PATH="/opt/zig:${PATH}"

WORKDIR /app
COPY . .

# Use Zig's built-in cross-compilation to build for the target architecture
ARG TARGETARCH
ARG TARGETVARIANT
ARG VERSION=""
RUN set -eu; \
    case "${TARGETARCH}${TARGETVARIANT:-}" in \
      amd64) target="x86_64-linux-musl"; cpu="" ;; \
      arm64) target="aarch64-linux-musl"; cpu="" ;; \
      armv7) target="arm-linux-musleabihf"; cpu="cortex_a7" ;; \
      *) echo "unsupported Docker target platform: ${TARGETARCH}${TARGETVARIANT:-}" >&2; exit 1 ;; \
    esac; \
    set -- -Doptimize=ReleaseSafe "-Dtarget=${target}"; \
    if [ -n "$cpu" ]; then set -- "$@" "-Dcpu=${cpu}"; fi; \
    if [ -n "$VERSION" ]; then set -- "$@" "-Dversion=${VERSION}"; fi; \
    zig build "$@"

# Create the default minimal image.
FROM busybox:1.37.0-musl AS runtime
WORKDIR /app

# Scoot needs CA certificates to make HTTPS requests to AI providers
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/

# Copy the compiled executable from the builder stage
COPY --from=builder /app/zig-out/bin/scoot /usr/local/bin/scoot

# Provide the CLI as the entrypoint
ENTRYPOINT ["scoot"]

# Create an Alpine runtime variant for users who prefer an apk-based base image.
FROM alpine:${ALPINE_VERSION} AS runtime-alpine
WORKDIR /app

COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
COPY --from=builder /app/zig-out/bin/scoot /usr/local/bin/scoot

ENTRYPOINT ["scoot"]

FROM runtime AS final
