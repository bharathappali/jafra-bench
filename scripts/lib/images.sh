#!/usr/bin/env bash
# Container image + Kind lifecycle helpers.
# Prefer Podman; fall back to Docker only if Podman is unavailable.
# shellcheck source=common.sh
# Intentionally sourced only after common.sh

# ---------------------------------------------------------------------------
# Container engine selection
# ---------------------------------------------------------------------------

resolve_container_engine() {
  if [[ -n "${CONTAINER_ENGINE:-}" ]]; then
    command -v "${CONTAINER_ENGINE}" >/dev/null 2>&1 \
      || die "CONTAINER_ENGINE='${CONTAINER_ENGINE}' not found on PATH"
    printf '%s' "${CONTAINER_ENGINE}"
    return
  fi
  if command -v podman >/dev/null 2>&1; then
    printf 'podman'
    return
  fi
  if command -v docker >/dev/null 2>&1; then
    printf 'docker'
    return
  fi
  die "Neither podman nor docker is available. Install podman (preferred) or docker."
}

# Set once when images.sh is sourced after common.sh in callers that need it.
# Callers should invoke init_container_engine early.
init_container_engine() {
  CONTAINER_ENGINE="$(resolve_container_engine)"
  export CONTAINER_ENGINE
  info "Container engine: ${CONTAINER_ENGINE}"
}

ctr() {
  # shellcheck disable=SC2086
  "${CONTAINER_ENGINE}" "$@"
}

# ---------------------------------------------------------------------------
# Image inspect / tag helpers (engine-agnostic)
# ---------------------------------------------------------------------------

ctr_image_exists() {
  local image="$1"
  ctr image inspect "${image}" >/dev/null 2>&1 \
    || ctr inspect "${image}" >/dev/null 2>&1
}

ctr_image_id() {
  local image="$1"
  ctr image inspect --format '{{.Id}}' "${image}" 2>/dev/null \
    || ctr inspect --format '{{.Id}}' "${image}" 2>/dev/null \
    || true
}

ctr_image_digest_or_id() {
  local image="$1"
  local digest
  digest="$(ctr image inspect --format '{{index .RepoDigests 0}}' "${image}" 2>/dev/null || true)"
  if [[ -z "${digest}" || "${digest}" == "<no value>" ]]; then
    digest="$(ctr inspect --format '{{index .RepoDigests 0}}' "${image}" 2>/dev/null || true)"
  fi
  if [[ -n "${digest}" && "${digest}" != "<no value>" ]]; then
    printf '%s' "${digest}"
  else
    ctr_image_id "${image}"
  fi
}

ctr_tag() {
  local src="$1"
  local dst="$2"
  if [[ "${CONTAINER_ENGINE}" == "podman" ]]; then
    ctr tag "${src}" "${dst}"
  else
    ctr tag "${src}" "${dst}"
  fi
}

host_container_platform() {
  local arch
  arch="$(uname -m)"
  case "${arch}" in
    x86_64|amd64) printf 'linux/amd64' ;;
    aarch64|arm64) printf 'linux/arm64' ;;
    *) die "Unsupported host architecture for platform mapping: ${arch}" ;;
  esac
}

platform_arch_suffix() {
  local p="$1"
  printf '%s' "${p##*/}"
}

# ---------------------------------------------------------------------------
# Multi-arch build (Podman preferred)
# ---------------------------------------------------------------------------

ensure_docker_buildx_builder() {
  local builder_name="${BUILDX_BUILDER_NAME:-jafra-bench-multiarch}"
  docker buildx version >/dev/null 2>&1 \
    || die "docker buildx is required when falling back to Docker for multi-arch builds"
  if ! docker buildx inspect "${builder_name}" >/dev/null 2>&1; then
    info "Creating docker buildx builder '${builder_name}'"
    docker buildx create --name "${builder_name}" --driver docker-container --use >/dev/null
  else
    docker buildx use "${builder_name}" >/dev/null
  fi
  docker buildx inspect --bootstrap >/dev/null
}

build_multiarch_podman() {
  local image="$1"
  local dockerfile="$2"
  local ver="$3"
  local pkg="$4"
  local platforms="$5"
  local push="$6"
  local context="$7"

  local host_plat host_suffix
  host_plat="$(host_container_platform)"
  host_suffix="$(platform_arch_suffix "${host_plat}")"

  info "Building multi-arch with podman: ${image}"
  info "Platforms: ${platforms}"

  local plat
  local _old_ifs="${IFS}"
  IFS=','
  # shellcheck disable=SC2086
  set -- ${platforms}
  IFS="${_old_ifs}"

  local p
  for p in "$@"; do
    plat="$(echo "${p}" | tr -d '[:space:]')"
    [[ -n "${plat}" ]] || continue
    local suffix arch_image
    suffix="$(platform_arch_suffix "${plat}")"
    arch_image="${image}-${suffix}"

    info "podman build --platform ${plat} -> ${arch_image}"
    ctr build \
      --file "${dockerfile}" \
      --platform "${plat}" \
      --build-arg "RENAISSANCE_VERSION=${ver}" \
      --build-arg "RENAISSANCE_PACKAGE_VERSION=${pkg}" \
      --tag "${arch_image}" \
      "${context}"
  done

  local host_image="${image}-${host_suffix}"
  ctr_image_exists "${host_image}" \
    || die "Host-arch image missing after multi-arch build: ${host_image}"

  KIND_LOAD_IMAGE="${host_image}"
  export KIND_LOAD_IMAGE
  # Convenient alias for local runs / Kind Job image name.
  ctr_tag "${host_image}" "${image}"
  info "Host platform image: ${host_image} (also tagged ${image})"
  info "Arch tags: ${image}-amd64 / ${image}-arm64"

  if [[ "${push}" == "true" ]]; then
    local manifest="${image}"
    info "Creating/pushing multi-arch manifest: ${manifest}"
    ctr manifest rm "${manifest}" >/dev/null 2>&1 || true
    # Manifest create needs a free name; temporarily use -multi then push as image.
    local mlist="${image}-multiarch"
    ctr manifest rm "${mlist}" >/dev/null 2>&1 || true
    ctr manifest create "${mlist}"
    local _old_ifs2="${IFS}"
    IFS=','
    # shellcheck disable=SC2086
    set -- ${platforms}
    IFS="${_old_ifs2}"
    for p in "$@"; do
      plat="$(echo "${p}" | tr -d '[:space:]')"
      [[ -n "${plat}" ]] || continue
      ctr manifest add "${mlist}" "${image}-$(platform_arch_suffix "${plat}")"
    done
    ctr manifest push --all "${mlist}" "docker://${image}" \
      || ctr manifest push --all "${mlist}" "${image}"
    info "Pushed multi-arch manifest: ${image}"
  fi
}

build_multiarch_docker() {
  local image="$1"
  local dockerfile="$2"
  local ver="$3"
  local pkg="$4"
  local platforms="$5"
  local push="$6"
  local context="$7"

  local host_plat host_suffix
  host_plat="$(host_container_platform)"
  host_suffix="$(platform_arch_suffix "${host_plat}")"

  warn "Using Docker buildx fallback (podman not selected)"
  ensure_docker_buildx_builder

  if [[ "${push}" == "true" ]]; then
    docker buildx build \
      --file "${dockerfile}" \
      --build-arg "RENAISSANCE_VERSION=${ver}" \
      --build-arg "RENAISSANCE_PACKAGE_VERSION=${pkg}" \
      --platform "${platforms}" \
      --tag "${image}" \
      --push \
      "${context}"
    info "Pushed multi-arch manifest: ${image}"
    KIND_LOAD_IMAGE=""
    export KIND_LOAD_IMAGE
    return 0
  fi

  local plat
  local _old_ifs="${IFS}"
  IFS=','
  # shellcheck disable=SC2086
  set -- ${platforms}
  IFS="${_old_ifs}"

  local p
  for p in "$@"; do
    plat="$(echo "${p}" | tr -d '[:space:]')"
    [[ -n "${plat}" ]] || continue
    local suffix arch_image
    suffix="$(platform_arch_suffix "${plat}")"
    arch_image="${image}-${suffix}"
    info "docker buildx build --platform ${plat} -> ${arch_image}"
    docker buildx build \
      --file "${dockerfile}" \
      --build-arg "RENAISSANCE_VERSION=${ver}" \
      --build-arg "RENAISSANCE_PACKAGE_VERSION=${pkg}" \
      --platform "${plat}" \
      --tag "${arch_image}" \
      --load \
      "${context}"
  done

  local host_image="${image}-${host_suffix}"
  ctr_image_exists "${host_image}" \
    || die "Host-arch image missing after multi-arch build: ${host_image}"
  ctr_tag "${host_image}" "${image}"
  KIND_LOAD_IMAGE="${image}"
  export KIND_LOAD_IMAGE
  info "Tagged host platform image as primary: ${image} <- ${host_image}"
}

build_benchmark_image() {
  local name="$1"
  local image="$2"
  local force="${3:-false}"

  [[ -n "${CONTAINER_ENGINE:-}" ]] || init_container_engine

  case "${name}" in
    renaissance)
      local ver="${RENAISSANCE_VERSION:-v0.16.1}"
      local pkg
      pkg="$(package_version_from_tag "${ver}")"
      local dockerfile="${REPO_ROOT}/benchmarks/renaissance/Dockerfile"
      [[ -f "${dockerfile}" ]] || die "Missing Dockerfile: ${dockerfile}"
      [[ -d "${REPO_ROOT}/renaissance" ]] || die "Missing renaissance submodule at ${REPO_ROOT}/renaissance"

      local platforms="${IMAGE_PLATFORMS:-linux/amd64,linux/arm64}"
      local push="${IMAGE_PUSH:-false}"
      local host_plat host_suffix host_image
      host_plat="$(host_container_platform)"
      host_suffix="$(platform_arch_suffix "${host_plat}")"
      host_image="${image}-${host_suffix}"

      if [[ "${force}" != "true" && "${push}" != "true" ]]; then
        if ctr_image_exists "${host_image}" || ctr_image_exists "${image}"; then
          info "Reusing existing image (pass --force-build to rebuild)"
          if ctr_image_exists "${host_image}"; then
            KIND_LOAD_IMAGE="${host_image}"
          else
            KIND_LOAD_IMAGE="${image}"
          fi
          export KIND_LOAD_IMAGE
          return 0
        fi
      fi

      info "Building multi-arch image ${image}"
      info "Engine: ${CONTAINER_ENGINE}  Platforms: ${platforms}  Push: ${push}"

      if [[ "${CONTAINER_ENGINE}" == "podman" ]]; then
        build_multiarch_podman "${image}" "${dockerfile}" "${ver}" "${pkg}" "${platforms}" "${push}" "${REPO_ROOT}"
      else
        build_multiarch_docker "${image}" "${dockerfile}" "${ver}" "${pkg}" "${platforms}" "${push}" "${REPO_ROOT}"
      fi

      # Optional SHA tag on the host-arch image for traceability.
      local sha
      sha="$(git -C "${REPO_ROOT}/renaissance" rev-parse --short HEAD 2>/dev/null || true)"
      if [[ -n "${sha}" && "${push}" != "true" ]]; then
        local base_tag
        if [[ -n "${IMAGE_TAG:-}" ]]; then
          base_tag="${IMAGE_TAG}"
        else
          base_tag="${IMAGE_TAG_PREFIX}${ver}"
        fi
        local sha_src="${KIND_LOAD_IMAGE:-${host_image}}"
        local sha_tag="${IMAGE_REGISTRY}/${IMAGE_REPOSITORY}:${base_tag}-${sha}"
        if ctr_image_exists "${sha_src}"; then
          ctr_tag "${sha_src}" "${sha_tag}"
          info "Also tagged ${sha_tag}"
        fi
      fi
      ;;
    *)
      die "No build recipe for benchmark '${name}'"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Kind helpers
# ---------------------------------------------------------------------------

kind_cluster_exists() {
  local cluster="$1"
  kind get clusters 2>/dev/null | grep -qx "${cluster}"
}

kind_node_name() {
  local cluster="$1"
  printf '%s-control-plane' "${cluster}"
}

# Exec into the Kind node container using whichever engine holds it.
kind_node_exec() {
  local node="$1"
  shift
  if command -v podman >/dev/null 2>&1 && podman inspect "${node}" >/dev/null 2>&1; then
    podman exec "${node}" "$@"
  elif command -v docker >/dev/null 2>&1 && docker inspect "${node}" >/dev/null 2>&1; then
    docker exec "${node}" "$@"
  else
    # Last resort: try selected container engine.
    ctr exec "${node}" "$@"
  fi
}

kind_image_id_on_node() {
  local cluster="$1"
  local image="$2"
  local node
  node="$(kind_node_name "${cluster}")"

  if kind_node_exec "${node}" crictl inspecti "${image}" >/dev/null 2>&1; then
    kind_node_exec "${node}" crictl inspecti --output go-template --template '{{.status.id}}' "${image}" 2>/dev/null \
      || kind_node_exec "${node}" crictl inspecti "${image}" 2>/dev/null | sed -n 's/.*"id": "\(sha256:[^"]*\)".*/\1/p' | head -n1
    return 0
  fi

  local id
  id="$(kind_node_exec "${node}" ctr -n k8s.io images ls 2>/dev/null | awk -v img="${image}" '$1 == img { print $3; exit }' || true)"
  printf '%s' "${id}"
}

kind_remove_image() {
  local cluster="$1"
  local image="$2"
  local node
  node="$(kind_node_name "${cluster}")"
  info "Removing image ${image} from Kind node ${node} (if present)"

  if kind_node_exec "${node}" crictl rmi "${image}" >/dev/null 2>&1; then
    info "Removed via crictl: ${image}"
    return 0
  fi
  if kind_node_exec "${node}" ctr -n k8s.io images rm "${image}" >/dev/null 2>&1; then
    info "Removed via ctr: ${image}"
    return 0
  fi
  warn "Image ${image} was not present on Kind node (or could not be removed); continuing"
}

kind_load_image() {
  local cluster="$1"
  local image="$2"
  info "Loading ${image} into Kind cluster '${cluster}' (engine=${CONTAINER_ENGINE:-unknown})"

  if [[ "${CONTAINER_ENGINE}" == "podman" ]]; then
    # kind load docker-image talks to the Docker API; with Podman use an archive.
    local tmp
    tmp="$(mktemp -t jafra-kind-image.XXXXXX.tar)"
    # shellcheck disable=SC2064
    trap "rm -f '${tmp}'" RETURN
    info "Saving ${image} via podman -> ${tmp}"
    ctr save -o "${tmp}" "${image}"
    kind load image-archive "${tmp}" --name "${cluster}"
  else
    kind load docker-image "${image}" --name "${cluster}"
  fi
}

kind_verify_image_loaded() {
  local cluster="$1"
  local image="$2"
  local expect_id="${3:-}"
  local node
  node="$(kind_node_name "${cluster}")"

  local found=""
  if kind_node_exec "${node}" crictl images 2>/dev/null | grep -F "${image%:*}" | grep -Fq "${image##*:}"; then
    found="yes"
  elif kind_node_exec "${node}" ctr -n k8s.io images ls 2>/dev/null | awk '{print $1}' | grep -Fxq "${image}"; then
    found="yes"
  elif kind_node_exec "${node}" ctr -n k8s.io images ls 2>/dev/null | grep -Fq "${image}"; then
    found="yes"
  fi

  [[ -n "${found}" ]] || die "Kind cluster '${cluster}' does not contain image ${image} after load"

  if [[ -n "${expect_id}" ]]; then
    local kind_id
    kind_id="$(kind_image_id_on_node "${cluster}" "${image}" || true)"
    KIND_IMAGE_ID="${kind_id:-unknown}"
    export KIND_IMAGE_ID
    if [[ -n "${kind_id}" && "${kind_id}" != "unknown" ]]; then
      local a b
      a="${expect_id#sha256:}"
      b="${kind_id#sha256:}"
      if [[ "${#a}" -ge 12 && "${#b}" -ge 12 ]]; then
        if [[ "${a:0:12}" != "${b:0:12}" ]]; then
          warn "Kind image ID (${kind_id}) does not match local image ID (${expect_id})"
          warn "This can happen across runtimes; verify Pod imageID after schedule."
        fi
      fi
    fi
  fi
  info "Verified image present in Kind: ${image}"
}

# Resolve which local tag Kind should load (host-arch after multi-arch builds).
resolve_kind_load_image() {
  local image="$1"
  if [[ -n "${KIND_LOAD_IMAGE:-}" ]] && ctr_image_exists "${KIND_LOAD_IMAGE}"; then
    printf '%s' "${KIND_LOAD_IMAGE}"
    return
  fi
  local host_image="${image}-$(platform_arch_suffix "$(host_container_platform)")"
  if ctr_image_exists "${host_image}"; then
    printf '%s' "${host_image}"
    return
  fi
  if ctr_image_exists "${image}"; then
    printf '%s' "${image}"
    return
  fi
  if ctr_image_exists "${image}-local"; then
    printf '%s' "${image}-local"
    return
  fi
  die "No local image found to load into Kind for ${image}"
}

ensure_kind_image_fresh() {
  local cluster="$1"
  local image="$2"
  local force_build="${3:-false}"

  [[ -n "${CONTAINER_ENGINE:-}" ]] || init_container_engine

  local load_image
  load_image="$(resolve_kind_load_image "${image}")"
  info "Kind will load: ${load_image}"

  local local_id
  local_id="$(ctr_image_id "${load_image}")"
  [[ -n "${local_id}" ]] || die "Local image missing: ${load_image}"
  LOCAL_IMAGE_ID="${local_id}"
  export LOCAL_IMAGE_ID
  KIND_LOAD_IMAGE="${load_image}"
  export KIND_LOAD_IMAGE

  local kind_id
  kind_id="$(kind_image_id_on_node "${cluster}" "${load_image}" || true)"
  # Also try removing the logical image name Kind pods reference.
  if [[ "${force_build}" == "true" ]]; then
    kind_remove_image "${cluster}" "${load_image}"
    kind_remove_image "${cluster}" "${image}"
  elif [[ -n "${kind_id}" ]]; then
    local a b
    a="${local_id#sha256:}"
    b="${kind_id#sha256:}"
    if [[ -n "${b}" && "${a:0:12}" != "${b:0:12}" ]]; then
      info "Local image ID differs from Kind; removing stale Kind image"
      kind_remove_image "${cluster}" "${load_image}"
      kind_remove_image "${cluster}" "${image}"
    fi
  fi

  kind_load_image "${cluster}" "${load_image}"
  kind_verify_image_loaded "${cluster}" "${load_image}" "${local_id}"

  # If Job references ${image} but we loaded ${image}-arm64, also tag/load under
  # the Job's image name inside Kind by loading a retagged archive when names differ.
  if [[ "${load_image}" != "${image}" ]]; then
    info "Also tagging ${load_image} as ${image} for Job imagePullPolicy matching"
    ctr_tag "${load_image}" "${image}"
    kind_remove_image "${cluster}" "${image}"
    kind_load_image "${cluster}" "${image}"
    kind_verify_image_loaded "${cluster}" "${image}" "$(ctr_image_id "${image}")"
  fi
}

# Back-compat aliases used by older call sites
docker_image_exists() { ctr_image_exists "$@"; }
docker_image_id() { ctr_image_id "$@"; }
docker_image_digest_or_id() { ctr_image_digest_or_id "$@"; }
