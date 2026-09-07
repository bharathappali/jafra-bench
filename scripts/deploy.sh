#!/usr/bin/env bash
# Generic benchmark deployer for jafra-bench.
# Benchmark-specific knobs live under benchmarks/<name>/; this script is generic.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/images.sh
source "${SCRIPT_DIR}/lib/images.sh"
# shellcheck source=lib/k8s.sh
source "${SCRIPT_DIR}/lib/k8s.sh"

usage() {
  cat <<'EOF'
Usage:
  deploy.sh --target kind --benchmark <name> [options]
  deploy.sh --target openshift --benchmark <name> [options]
  deploy.sh --target kind --benchmark <name> --cleanup

Options:
  --target TARGET        kind | openshift
  --benchmark NAME       Benchmark directory under benchmarks/ (e.g. renaissance)
  --force-build          Rebuild image and replace stale Kind image before deploy
  --cleanup              Delete this benchmark's K8s resources (and Kind image tag)
  --cluster NAME         Kind cluster name (default: jafra)
  --namespace NAME       Kubernetes namespace (default: jafra-bench)
  --image-tag TAG        Full image tag (e.g. renaissance-movie-lens-jafra-v0.16.1)
  --platforms LIST       Comma-separated platforms (default: linux/amd64,linux/arm64)
  --push                 Push multi-arch manifest to registry when building
  --set KEY=VALUE        Override config (repeatable), e.g. --set BENCHMARKS=movie-lens
  -h, --help             Show this help

Examples:
  ./scripts/deploy.sh --target kind --benchmark renaissance
  ./scripts/deploy.sh --target kind --benchmark renaissance --force-build
  ./scripts/deploy.sh --target kind --benchmark renaissance \\
    --image-tag renaissance-movie-lens-jafra-v0.16.1 --force-build
  ./scripts/deploy.sh --target kind --benchmark renaissance --set BENCHMARKS=movie-lens \\
    --set 'RENAISSANCE_ARGS=-c jafra-stress -r 1 --scratch-base /tmp/renaissance-scratch'
  ./scripts/deploy.sh --target kind --benchmark renaissance --cleanup
EOF
}

TARGET=""
BENCHMARK=""
FORCE_BUILD="false"
CLEANUP="false"
IMAGE_TAG_CLI=""
PLATFORMS_CLI=""
PUSH_CLI=""
SET_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target) TARGET="$2"; shift 2 ;;
    --benchmark) BENCHMARK="$2"; shift 2 ;;
    --force-build) FORCE_BUILD="true"; shift ;;
    --cleanup) CLEANUP="true"; shift ;;
    --cluster) KIND_CLUSTER_NAME="$2"; shift 2 ;;
    --namespace) NAMESPACE="$2"; shift 2 ;;
    --image-tag) IMAGE_TAG_CLI="$2"; shift 2 ;;
    --platforms) PLATFORMS_CLI="$2"; shift 2 ;;
    --push) PUSH_CLI="true"; shift ;;
    --set)
      SET_ARGS+=("$2")
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ -n "${TARGET}" ]] || die "--target is required (kind|openshift)"
[[ -n "${BENCHMARK}" ]] || die "--benchmark is required"

apply_set_overrides() {
  local pair key val
  local i
  i=0
  while [[ ${i} -lt ${#SET_ARGS[@]} ]]; do
    pair="${SET_ARGS[$i]}"
    [[ "${pair}" == *=* ]] || die "Invalid --set '${pair}' (expected KEY=VALUE)"
    key="${pair%%=*}"
    val="${pair#*=}"
    export "${key}=${val}"
    i=$((i + 1))
  done
}

deploy_openshift() {
  cat <<EOF
OpenShift target is not fully implemented in this repository.

What differs from Kind (for a future implementation):
  - Images must be pushed to an OpenShift-accessible registry (or the integrated registry),
    not loaded via \`kind load\`.
  - Prefer imagePullPolicy: Always (or digest pins) with registry pulls.
  - Workload Pods using emptyDir + Jafra injection do not need a privileged SCC;
    the jafra-agent DaemonSet (platform) uses a custom SCC — that is out of scope here.
  - Routes / NetworkPolicies may differ; cert-manager remains a Jafra platform concern.

Unsupported now: build-push-deploy against OpenShift.
EOF
  exit 2
}

cleanup_kind() {
  require_cmd kubectl kind
  init_container_engine
  load_project_env
  load_benchmark_env "${BENCHMARK}"
  apply_set_overrides
  if [[ -n "${IMAGE_TAG_CLI}" ]]; then
    IMAGE_TAG="${IMAGE_TAG_CLI}"
  fi
  export IMAGE_TAG
  KIND_CLUSTER_NAME="${KIND_CLUSTER_NAME:-jafra}"
  NAMESPACE="${NAMESPACE:-jafra-bench}"

  if ! kind_cluster_exists "${KIND_CLUSTER_NAME}"; then
    warn "Kind cluster '${KIND_CLUSTER_NAME}' not found; skipping Kind image cleanup"
  else
    IMAGE="$(image_ref_for_benchmark "${BENCHMARK}")"
    kind_remove_image "${KIND_CLUSTER_NAME}" "${IMAGE}"
    kind_remove_image "${KIND_CLUSTER_NAME}" "${IMAGE}-amd64"
    kind_remove_image "${KIND_CLUSTER_NAME}" "${IMAGE}-arm64"
  fi

  if kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1; then
    delete_benchmark_resources "${NAMESPACE}" "${BENCHMARK}"
  else
    warn "Namespace ${NAMESPACE} not found; nothing to delete"
  fi
  info "Cleanup complete for benchmark '${BENCHMARK}'"
}

deploy_kind() {
  require_cmd kind kubectl envsubst
  init_container_engine
  load_project_env
  load_benchmark_env "${BENCHMARK}"
  apply_set_overrides

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

  # Kind needs a locally loaded image for the node arch; multi-arch --push
  # alone does not populate the local engine for kind load.
  if [[ "${IMAGE_PUSH}" == "true" ]]; then
    warn "Kind deploy builds/loads local arch tags; ignoring --push for this path"
    IMAGE_PUSH="false"
    export IMAGE_PUSH
  fi

  KIND_CLUSTER_NAME="${KIND_CLUSTER_NAME:-jafra}"
  NAMESPACE="${NAMESPACE:-jafra-bench}"
  IMAGE_PULL_POLICY="${IMAGE_PULL_POLICY:-IfNotPresent}"

  if ver="$(resolve_renaissance_version)"; then
    [[ -n "${ver}" ]] && RENAISSANCE_VERSION="${ver}"
  fi
  export RENAISSANCE_VERSION NAMESPACE KIND_CLUSTER_NAME IMAGE_PULL_POLICY

  IMAGE="$(image_ref_for_benchmark "${BENCHMARK}")"
  export IMAGE

  kind_cluster_exists "${KIND_CLUSTER_NAME}" \
    || die "Kind cluster '${KIND_CLUSTER_NAME}' does not exist. Create it (and install Jafra) first."

  check_jafra_prerequisites

  build_benchmark_image "${BENCHMARK}" "${IMAGE}" "${FORCE_BUILD}"
  ensure_kind_image_fresh "${KIND_CLUSTER_NAME}" "${IMAGE}" "${FORCE_BUILD}"

  # Replace existing Job so re-deploys are clean.
  kubectl delete job "${JOB_NAME}" -n "${NAMESPACE}" --ignore-not-found=true >/dev/null 2>&1 || true

  ensure_namespace "${NAMESPACE}"

  local rendered="${REPO_ROOT}/.k8s-rendered/${BENCHMARK}-job.yaml"
  render_manifest "${BENCHMARK_DIR}/k8s/job.yaml" "${rendered}"
  apply_manifest "${rendered}"

  local pod
  pod="$(wait_for_job_pod "${NAMESPACE}" "${JOB_NAME}" 300)"
  verify_pod_image "${NAMESPACE}" "${pod}" "${CONTAINER_NAME}" "${IMAGE}"
  pod_has_jafra_injection "${NAMESPACE}" "${pod}" || warn "Continue carefully; JFRs may not be produced."

  print_image_report
  info "Container engine: ${CONTAINER_ENGINE}"
  info "Pod: ${pod}"
  info "Logs: kubectl logs -n ${NAMESPACE} ${pod} -c ${CONTAINER_NAME} -f"
  info "Collect JFRs: ./scripts/collect-jfr.sh --benchmark ${BENCHMARK} --namespace ${NAMESPACE}"
}

case "${TARGET}" in
  kind)
    if [[ "${CLEANUP}" == "true" ]]; then
      cleanup_kind
    else
      deploy_kind
    fi
    ;;
  openshift)
    if [[ "${CLEANUP}" == "true" ]]; then
      die "OpenShift cleanup is not implemented yet"
    fi
    deploy_openshift
    ;;
  *)
    die "Unknown --target '${TARGET}' (expected kind|openshift)"
    ;;
esac
