#!/usr/bin/env bash
# Shared helpers for jafra-bench scripts.
set -euo pipefail

SCRIPT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_LIB_DIR}/../.." && pwd)"

log()  { printf '%s\n' "$*" >&2; }
info() { printf '==> %s\n' "$*" >&2; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

require_cmd() {
  local c
  for c in "$@"; do
    command -v "${c}" >/dev/null 2>&1 || die "Required command not found: ${c}"
  done
}

load_env_file() {
  local f="$1"
  if [[ -f "${f}" ]]; then
    # shellcheck disable=SC1090
    set -a
    # shellcheck disable=SC1090
    source "${f}"
    set +a
  fi
}

load_project_env() {
  load_env_file "${REPO_ROOT}/config/defaults.env"
  if [[ -f "${REPO_ROOT}/config/local.env" ]]; then
    load_env_file "${REPO_ROOT}/config/local.env"
  fi
}

load_benchmark_env() {
  local name="$1"
  local path="${REPO_ROOT}/benchmarks/${name}/benchmark.env"
  [[ -f "${path}" ]] || die "Unknown benchmark '${name}' (missing ${path})"
  load_env_file "${path}"
  BENCHMARK_DIR="${REPO_ROOT}/benchmarks/${name}"
  export BENCHMARK_DIR
}

resolve_renaissance_version() {
  # Prefer explicit env, else git describe on submodule, else benchmark.env default.
  if [[ -n "${RENAISSANCE_VERSION:-}" ]]; then
    printf '%s' "${RENAISSANCE_VERSION}"
    return
  fi
  if [[ -d "${REPO_ROOT}/renaissance/.git" ]] || [[ -f "${REPO_ROOT}/renaissance/.git" ]]; then
    git -C "${REPO_ROOT}/renaissance" describe --tags --always 2>/dev/null || true
  fi
}

package_version_from_tag() {
  # v0.16.1 -> 0.16.1
  local v="$1"
  printf '%s' "${v#v}"
}

image_ref_for_benchmark() {
  local name="$1"
  case "${name}" in
    renaissance)
      # Prefer an explicit full tag (e.g. renaissance-movie-lens-jafra-v0.16.1).
      if [[ -n "${IMAGE_TAG:-}" ]]; then
        printf '%s/%s:%s' "${IMAGE_REGISTRY}" "${IMAGE_REPOSITORY}" "${IMAGE_TAG}"
        return
      fi
      local ver="${RENAISSANCE_VERSION:-v0.16.1}"
      printf '%s/%s:%s%s' \
        "${IMAGE_REGISTRY}" "${IMAGE_REPOSITORY}" "${IMAGE_TAG_PREFIX:-renaissance_}" "${ver}"
      ;;
    *)
      die "No image naming rule for benchmark '${name}'"
      ;;
  esac
}

print_image_report() {
  cat <<EOF
Benchmark:              ${BENCHMARK_NAME:-?}
Image:                  ${IMAGE:-?}
Local image ID:         ${LOCAL_IMAGE_ID:-?}
Kind image ID:          ${KIND_IMAGE_ID:-n/a}
Kubernetes pod image:   ${POD_IMAGE:-n/a}
Pod container imageID:  ${POD_IMAGE_ID:-n/a}
EOF
}
