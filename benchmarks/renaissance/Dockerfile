# syntax=docker/dockerfile:1.6

# Build Renaissance from the git submodule source (never download a release JAR).
# Expected build context: repository root (contains ./renaissance).
#
# Multi-arch notes:
# - The fat JAR is JVM bytecode (architecture-independent), so the build stage
#   runs on $BUILDPLATFORM (host) once.
# - The runtime stage is per-target ($TARGETPLATFORM) so amd64 and arm64
#   images get the matching Temurin JRE.

ARG JDK_IMAGE=eclipse-temurin:21-jdk-jammy
ARG JRE_IMAGE=eclipse-temurin:21-jre-jammy

# ---------------------------------------------------------------------------
# Stage 1: compile fat JAR (once, on the build host architecture)
# ---------------------------------------------------------------------------
FROM --platform=$BUILDPLATFORM ${JDK_IMAGE} AS build

ARG RENAISSANCE_VERSION=v0.16.1
# sbt package version without leading 'v'
ARG RENAISSANCE_PACKAGE_VERSION=0.16.1
ARG TARGETARCH
ARG BUILDARCH

WORKDIR /src

# Copy only the submodule tree needed to build.
COPY renaissance/ /src/renaissance/

WORKDIR /src/renaissance

# Renaissance build.sbt installs a pre-push git hook on load. The Docker
# context excludes .git (submodule), so create the hooks dir before sbt runs.
# Override version so the JAR name is deterministic without git describe
# (version.sbt baseVersion is 0.17.0 when git metadata is unavailable).
RUN mkdir -p .git/hooks \
 && tools/sbt/bin/sbt -batch \
    "set ThisBuild / version := \"${RENAISSANCE_PACKAGE_VERSION}\"" \
    renaissancePackage \
 && JAR="$(ls -1 target/renaissance-gpl-*.jar | head -n1)" \
 && test -n "${JAR}" \
 && cp "${JAR}" /tmp/renaissance.jar \
 && echo "Built ${JAR} (RENAISSANCE_VERSION=${RENAISSANCE_VERSION}, BUILDARCH=${BUILDARCH}, TARGETARCH=${TARGETARCH})"

# ---------------------------------------------------------------------------
# Stage 2: runtime (per-target architecture)
# ---------------------------------------------------------------------------
FROM ${JRE_IMAGE} AS runtime

ARG RENAISSANCE_VERSION=v0.16.1
ARG TARGETARCH

LABEL org.opencontainers.image.title="jafra-bench renaissance" \
      org.opencontainers.image.description="Renaissance JVM benchmark for Jafra JFR collection" \
      org.opencontainers.image.version="${RENAISSANCE_VERSION}" \
      org.opencontainers.image.source="https://github.com/bharathappali/renaissance" \
      org.opencontainers.image.architecture="${TARGETARCH}"

RUN groupadd --system --gid 10001 renaissance \
 && useradd --system --uid 10001 --gid renaissance --home-dir /opt/renaissance --shell /usr/sbin/nologin renaissance \
 && mkdir -p /opt/renaissance /tmp/renaissance-scratch \
 && chown -R renaissance:renaissance /opt/renaissance /tmp/renaissance-scratch

COPY --from=build /tmp/renaissance.jar /opt/renaissance/renaissance.jar
COPY benchmarks/renaissance/entrypoint.sh /opt/renaissance/entrypoint.sh

RUN chmod 755 /opt/renaissance/entrypoint.sh \
 && chown renaissance:renaissance /opt/renaissance/renaissance.jar /opt/renaissance/entrypoint.sh

# Defaults for local docker run; Kubernetes Job sets these explicitly.
ENV BENCHMARKS="dummy-empty" \
    RENAISSANCE_ARGS="-r 1 --scratch-base /tmp/renaissance-scratch" \
    JAVA_OPTS="-Xms512m -Xmx1536m" \
    RENAISSANCE_JAR=/opt/renaissance/renaissance.jar

WORKDIR /opt/renaissance
USER renaissance:renaissance

ENTRYPOINT ["/opt/renaissance/entrypoint.sh"]
