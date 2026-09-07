#!/usr/bin/env bash
# Kubernetes helpers for jafra-bench.
# shellcheck source=common.sh

render_manifest() {
  local template="$1"
  local outfile="$2"
  require_cmd envsubst
  mkdir -p "$(dirname "${outfile}")"
  # Export only the vars we intentionally substitute.
  # shellcheck disable=SC2016
  envsubst '${NAMESPACE} ${JOB_NAME} ${CONTAINER_NAME} ${IMAGE} ${IMAGE_PULL_POLICY} ${BENCHMARKS} ${RENAISSANCE_ARGS} ${JAVA_OPTS} ${CPU_REQUEST} ${CPU_LIMIT} ${MEMORY_REQUEST} ${MEMORY_LIMIT} ${ACTIVE_DEADLINE_SECONDS} ${JAFRA_LOOP} ${JAFRA_JFRSYNC}' \
    < "${template}" > "${outfile}"
  info "Rendered ${outfile}"
}

apply_manifest() {
  local file="$1"
  kubectl apply -f "${file}"
}

delete_benchmark_resources() {
  local ns="$1"
  local benchmark="$2"
  info "Deleting Kubernetes resources for benchmark '${benchmark}' in namespace '${ns}'"
  kubectl delete job,pod \
    -n "${ns}" \
    -l "app.kubernetes.io/part-of=jafra-bench,jafra-bench.benchmark=${benchmark}" \
    --ignore-not-found=true
}

ensure_namespace() {
  local ns="$1"
  kubectl get namespace "${ns}" >/dev/null 2>&1 || kubectl create namespace "${ns}"
  kubectl label namespace "${ns}" \
    app.kubernetes.io/part-of=jafra-bench \
    app.kubernetes.io/managed-by=jafra-bench-deploy \
    --overwrite >/dev/null
}

check_jafra_prerequisites() {
  local ns="${JAFRA_SYSTEM_NAMESPACE:-jafra-system}"
  local deploy="${JAFRA_CONTROLLER_DEPLOYMENT:-jafra-controller}"

  info "Checking Jafra platform prerequisites (assumed pre-installed)"

  if ! kubectl get namespace "${ns}" >/dev/null 2>&1; then
    die "Jafra namespace '${ns}' not found. Install Jafra before deploying benchmarks."
  fi

  if ! kubectl get deployment "${deploy}" -n "${ns}" >/dev/null 2>&1; then
    die "Jafra controller deployment '${deploy}' not found in '${ns}'. Install Jafra before deploying benchmarks."
  fi

  local ready
  ready="$(kubectl get deployment "${deploy}" -n "${ns}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
  if [[ -z "${ready}" || "${ready}" == "0" ]]; then
    die "Jafra controller '${deploy}' in '${ns}' has no ready replicas."
  fi

  if ! kubectl get mutatingwebhookconfiguration 2>/dev/null | grep -qi jafra; then
    warn "No MutatingWebhookConfiguration matching 'jafra' found; Pod injection may fail."
  fi

  info "Jafra controller is present and ready in ${ns}"
}

wait_for_job_pod() {
  local ns="$1"
  local job="$2"
  local timeout="${3:-300}"

  info "Waiting for Job/${job} pod in ${ns} (timeout ${timeout}s)"
  local end=$((SECONDS + timeout))
  local pod=""
  while (( SECONDS < end )); do
    pod="$(kubectl get pods -n "${ns}" -l "job-name=${job}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    if [[ -n "${pod}" ]]; then
      local phase
      phase="$(kubectl get pod "${pod}" -n "${ns}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
      case "${phase}" in
        Pending|ContainerCreating|PodInitializing)
          sleep 2
          continue
          ;;
        Running|Succeeded)
          printf '%s' "${pod}"
          return 0
          ;;
        Failed)
          kubectl describe pod "${pod}" -n "${ns}" >&2 || true
          kubectl logs "${pod}" -n "${ns}" -c "${CONTAINER_NAME:-renaissance}" --all-containers=true >&2 || true
          die "Pod ${pod} failed"
          ;;
      esac
    fi
    sleep 2
  done
  die "Timed out waiting for Job/${job} pod"
}

verify_pod_image() {
  local ns="$1"
  local pod="$2"
  local container="$3"
  local expect_image="$4"

  POD_IMAGE="$(kubectl get pod "${pod}" -n "${ns}" -o jsonpath="{.spec.containers[?(@.name==\"${container}\")].image}" 2>/dev/null || true)"
  POD_IMAGE_ID="$(kubectl get pod "${pod}" -n "${ns}" -o jsonpath="{.status.containerStatuses[?(@.name==\"${container}\")].imageID}" 2>/dev/null || true)"
  export POD_IMAGE POD_IMAGE_ID

  [[ -n "${POD_IMAGE}" ]] || die "Could not read image for container ${container} on pod ${pod}"
  if [[ "${POD_IMAGE}" != "${expect_image}" ]]; then
    die "Pod is using unexpected image '${POD_IMAGE}' (expected '${expect_image}')"
  fi
  info "Pod ${pod} container ${container} image OK: ${POD_IMAGE}"
  if [[ -n "${POD_IMAGE_ID}" ]]; then
    info "Pod container imageID: ${POD_IMAGE_ID}"
  fi
}

pod_has_jafra_injection() {
  local ns="$1"
  local pod="$2"
  local injected
  injected="$(kubectl get pod "${pod}" -n "${ns}" -o jsonpath='{.metadata.annotations.jafra\.io/injected}' 2>/dev/null || true)"
  if [[ "${injected}" != "true" ]]; then
    warn "Pod ${pod} is missing annotation jafra.io/injected=true (webhook may not have mutated the Pod)"
    return 1
  fi
  info "Jafra injection confirmed on ${pod} (jafra.io/injected=true)"
  return 0
}
