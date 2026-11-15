# syntax=docker/dockerfile:1
#
# Shutterlink Sessions server. Build from the repository root, which holds
# the workspace lockfile:
#
#   docker build -f server/Dockerfile -t shutterlink-server .

# Same Dart as the Flutter SDK that CI tests with (.fvmrc / FLUTTER_VERSION).
# Runs on the build machine and cross-compiles for the target platform.
FROM --platform=$BUILDPLATFORM dart:3.13.4@sha256:33faf91bc941466a767ce845b4bbb5d578ecd180abe5ee243e9c8c039109d215 AS build
ARG TARGETARCH
WORKDIR /build/server

# server/ is a member of the Flutter workspace at the repository root, and
# resolving that needs the Flutter SDK. Resolve the server on its own, seeded
# with the workspace lockfile so it gets the same package versions.
COPY server/pubspec.yaml ./
COPY pubspec.lock ./
RUN sed -i '/^resolution: workspace$/d' pubspec.yaml \
    && dart pub get

COPY server/bin ./bin
COPY server/lib ./lib
RUN case "$TARGETARCH" in \
      amd64) arch=x64 ;; \
      arm64) arch=arm64 ;; \
      *) echo "Unsupported TARGETARCH: $TARGETARCH" >&2; exit 1 ;; \
    esac \
    && dart compile exe --target-os=linux --target-arch="$arch" \
      bin/server.dart -o /build/shutterlink-server

# glibc for the AOT binary, and chmod, which the server runs once to make
# <data-dir>/secret owner-only.
FROM debian:trixie-slim@sha256:a72b4433de1cf7d6bae0c4cee74d0547f58601a643b3375f070c51600d63b6b2

LABEL org.opencontainers.image.title="Shutterlink Sessions server" \
      org.opencontainers.image.description="Self-hostable gallery server for Shutterlink Sessions" \
      org.opencontainers.image.source="https://github.com/micheljung/shutterlink" \
      org.opencontainers.image.licenses="MIT"

RUN groupadd --system --gid 10001 shutterlink \
    && useradd --system --uid 10001 --gid 10001 --no-create-home \
      --home-dir /data --shell /usr/sbin/nologin shutterlink \
    && install -d -o 10001 -g 10001 -m 0700 /data

COPY --from=build --chmod=0555 /build/shutterlink-server /app/server

USER 10001:10001
VOLUME /data
EXPOSE 8080

# Checks the default port. Override it as well when you change --port.
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --start-interval=2s \
  CMD ["/app/server", "--healthcheck"]

# Arguments after the image name are appended, and a repeated option wins
# over these defaults, e.g. `--retention-days 14` or `--port 9000`.
ENTRYPOINT ["/app/server", "--address=0.0.0.0", "--data-dir=/data"]
