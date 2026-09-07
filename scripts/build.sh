#!/usr/bin/env bash
# Build a benchmark image from source (no release JAR downloads).
# Prefer Podman; fall back to Docker. Multi-arch: linux/amd64 + linux/arm64.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/images.sh
source "${SCRIPT_DIR}/lib/images.sh"

usage() {
  cat <<'EOF'
Usage: build.sh --benchmark <name> [options]

Builds the benchmark container image from source (multi-arch by default).
Uses Podman when available; otherwise Docker.

Options:
  --benchmark NAME     Benchmark to build (e.g. renaissance)
  --force-build        Rebuild even if the image tag already exists locally
  --image-tag TAG      Full image tag (e.g. renaissance-movie-lens-jafra-v0.16.1)
  --platforms LIST     Comma-separated platforms (default: linux/amd64,linux/arm64)
  --push               Push a multi-arch manifest to the registry (requires login)
  -h, --help           Show this help

Examples:
  ./scripts/build.sh --benchmark renaissance --force-build
  ./scripts/build.sh --benchmark renaissance --image-tag renaissance-movie-lens-jafra-v0.16.1 --force-build
  ./scripts/build.sh --benchmark renaissance --platforms linux/amd64,linux/arm64 --push --force-build
EOF
}

BENCHMARK=""
FORCE_BUILD="false"
IMAGE_TAG_CLI=""
PLATFORMS_CLI=""
PUSH_CLI=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --benchmark) BENCHMARK="$2"; shift 2 ;;
    --force-build) FORCE_BUILD="true"; shift ;;
    --image-tag) IMAGE_TAG_CLI="$2"; shift 2 ;;
    --platforms) PLATFORMS_CLI="$2"; shift 2 ;;
    --push) PUSH_CLI="true"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ -n "${BENCHMARK}" ]] || die "--benchmark is required"

init_container_engine
load_project_env
load_benchmark_env "${BENCHMARK}"

# Prefer live submodule tag when available.
if ver="$(resolve_renaissance_version)"; then
  if [[ -n "${ver}" ]]; then
    RENAISSANCE_VERSION="${ver}"
  fi
fi
export RENAISSANCE_VERSION

if [[ -n "${IMAGE_TAG_CLI}" ]]; then
  IMAGE_TAG="${IMAGE_TAG_CLI}"
fi
export IMAGE_TAG

if [[ -n "${PLATFORMS_CLI}" ]]; then
  IMAGE_PLATFORMS="${PLATFORMS_CLI}"
fi
export IMAGE_PLATFORMS="${IMAGE_PLATFORMS:-linux/amd64,linux/arm64}"

if [[ -n "${PUSH_CLI}" ]]; then
  IMAGE_PUSH="${PUSH_CLI}"
fi
export IMAGE_PUSH="${IMAGE_PUSH:-false}"

IMAGE="$(image_ref_for_benchmark "${BENCHMARK}")"
export IMAGE

build_benchmark_image "${BENCHMARK}" "${IMAGE}" "${FORCE_BUILD}"

LOCAL_IMAGE_ID="$(ctr_image_id "${KIND_LOAD_IMAGE:-${IMAGE}}")"
export LOCAL_IMAGE_ID
info "Built/ready: ${IMAGE}"
info "Engine: ${CONTAINER_ENGINE}"
info "Platforms: ${IMAGE_PLATFORMS}"
info "Kind load image: ${KIND_LOAD_IMAGE:-${IMAGE}}"
info "Local image ID: ${LOCAL_IMAGE_ID:-n/a}"
print_image_report
