#!/usr/bin/env bash
# Collect JFR files from a jafra-bench benchmark Pod (/jfr-data).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/k8s.sh
source "${SCRIPT_DIR}/lib/k8s.sh"

usage() {
  cat <<'EOF'
Usage: collect-jfr.sh --benchmark <name> [--namespace NS] [--pod POD] [--out DIR]

Copies /jfr-data/profile-*.jfr from the benchmark container to a local directory.
Requires Jafra webhook injection (files appear under /jfr-data after async-profiler starts).

Options:
  --benchmark NAME   Benchmark name (used to find Job/Pod labels)
  --namespace NS     Kubernetes namespace (default: jafra-bench)
  --pod POD          Explicit Pod name (optional)
  --container NAME   Container name (default from benchmark.env)
  --out DIR          Output directory (default: artifacts/jfr/<benchmark>-<timestamp>)
  -h, --help         Show this help
EOF
}

BENCHMARK=""
POD=""
OUT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --benchmark) BENCHMARK="$2"; shift 2 ;;
    --namespace) NAMESPACE="$2"; shift 2 ;;
    --pod) POD="$2"; shift 2 ;;
    --container) CONTAINER_NAME="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ -n "${BENCHMARK}" ]] || die "--benchmark is required"
require_cmd kubectl
load_project_env
load_benchmark_env "${BENCHMARK}"
NAMESPACE="${NAMESPACE:-jafra-bench}"
CONTAINER_NAME="${CONTAINER_NAME:-renaissance}"

if [[ -z "${POD}" ]]; then
  POD="$(kubectl get pods -n "${NAMESPACE}" \
    -l "app.kubernetes.io/part-of=jafra-bench,jafra-bench.benchmark=${BENCHMARK}" \
    --sort-by=.metadata.creationTimestamp \
    -o jsonpath='{.items[-1:].metadata.name}' 2>/dev/null || true)"
fi
[[ -n "${POD}" ]] || die "No Pod found for benchmark '${BENCHMARK}' in namespace '${NAMESPACE}'"

phase="$(kubectl get pod "${POD}" -n "${NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
info "Using Pod ${POD} (phase=${phase})"

# List recordings
if ! kubectl exec -n "${NAMESPACE}" "${POD}" -c "${CONTAINER_NAME}" -- ls -la /jfr-data >/tmp/jafra-jfr-ls.$$ 2>/tmp/jafra-jfr-ls-err.$$; then
  cat /tmp/jafra-jfr-ls-err.$$ >&2 || true
  rm -f /tmp/jafra-jfr-ls.$$ /tmp/jafra-jfr-ls-err.$$
  die "Could not list /jfr-data on ${POD}. Is Jafra injection present? (check jafra.io/injected annotation)"
fi
info "Contents of /jfr-data:"
cat /tmp/jafra-jfr-ls.$$
rm -f /tmp/jafra-jfr-ls.$$ /tmp/jafra-jfr-ls-err.$$

FILE_LIST="$(kubectl exec -n "${NAMESPACE}" "${POD}" -c "${CONTAINER_NAME}" -- \
  sh -c 'ls -1 /jfr-data/profile-*.jfr 2>/dev/null' || true)"

if [[ -z "${FILE_LIST}" ]]; then
  die "No profile-*.jfr files found under /jfr-data yet. Wait for jafra.io/loop rotation (default override: 1m) and retry."
fi

ts="$(date +%Y%m%d-%H%M%S)"
OUT="${OUT:-${REPO_ROOT}/artifacts/jfr/${BENCHMARK}-${ts}}"
mkdir -p "${OUT}"

copied=0
# shellcheck disable=SC2034
while IFS= read -r remote; do
  [[ -n "${remote}" ]] || continue
  base="$(basename "${remote}")"
  local_path="${OUT}/${base}"
  info "Copying ${remote} -> ${local_path}"
  if kubectl cp -n "${NAMESPACE}" -c "${CONTAINER_NAME}" "${POD}:${remote}" "${local_path}"; then
    size="$(wc -c < "${local_path}" | tr -d ' ')"
    if [[ "${size}" -eq 0 ]]; then
      warn "${local_path} is empty"
    else
      info "OK ${base} (${size} bytes)"
      copied=$((copied + 1))
    fi
  else
    warn "Failed to copy ${remote}"
  fi
done <<EOF
${FILE_LIST}
EOF

[[ "${copied}" -gt 0 ]] || die "No non-empty JFR files collected"
info "Collected ${copied} JFR file(s) into ${OUT}"
info "Validate with: jfr summary ${OUT}/profile-0.jfr   # if JDK jfr tool is installed"
