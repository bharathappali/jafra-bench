# jafra-bench

Deploy JVM benchmarks into Kubernetes (Kind today; OpenShift stubbed) with
**Jafra** continuous profiling / JFR collection.

Jafra itself is **assumed pre-installed** in the cluster. This repository only
builds and deploys benchmark workloads with the correct opt-in labels.

`references/` (local Jafra clones) is **read-only** reference material and is
gitignored — do not modify it.

## Architecture

```text
benchmark source (submodule)
        |
        v
   Docker image
        |
        v
 Kubernetes Job (jafra.io labels)
        |
        v
   Kind cluster (Jafra webhook injects async-profiler)
        |
        v
   /jfr-data/profile-*.jfr  -->  scripts/collect-jfr.sh
```

## Prerequisites

- **Podman** (preferred) or Docker (fallback) with multi-arch support
- Kind
- kubectl
- `envsubst` (gettext)
- A Kind cluster with **Jafra already installed** (default cluster name: `jafra`)
- Git submodule `renaissance/` checked out (pinned to **v0.16.1**)

```bash
git submodule update --init --recursive
```

## Image naming

Default movie-lens / Jafra stress image:

```text
quay.io/bharathappali/jafra-bench:renaissance-movie-lens-jafra-v0.16.1
```

Set via `IMAGE_TAG` in `benchmarks/renaissance/benchmark.env`, or override:

```bash
./scripts/build.sh --benchmark renaissance --image-tag renaissance-movie-lens-jafra-v0.16.1 --force-build
./scripts/deploy.sh --target kind --benchmark renaissance --image-tag renaissance-movie-lens-jafra-v0.16.1 --force-build
```

## Build

Builds prefer **Podman**, then fall back to **Docker**. Multi-arch by default
(`linux/amd64` + `linux/arm64`).

```bash
# Local multi-arch (podman build --platform … / docker buildx fallback)
./scripts/build.sh --benchmark renaissance --force-build
./scripts/build.sh --benchmark renaissance --image-tag renaissance-movie-lens-jafra-v0.16.1 --force-build

# Push a multi-arch manifest to the registry (login required)
./scripts/build.sh --benchmark renaissance \
  --image-tag renaissance-movie-lens-jafra-v0.16.1 \
  --platforms linux/amd64,linux/arm64 \
  --push \
  --force-build
```

Notes:
- Force engine with `CONTAINER_ENGINE=podman` or `CONTAINER_ENGINE=docker`.
- JAR compile runs on the host build platform; runtime layers are per-arch.
- Kind loads via `podman save` + `kind load image-archive` when using Podman.
- Arch-specific tags: `…:tag-amd64` / `…:tag-arm64`.

## Deploy to Kind

```bash
./scripts/deploy.sh --target kind --benchmark renaissance
```

Force rebuild and replace the Kind-cached image:

```bash
./scripts/deploy.sh --target kind --benchmark renaissance --force-build
```

Movie-lens jafra-stress (default in `benchmark.env`):

```bash
./scripts/deploy.sh --target kind --benchmark renaissance \
  --image-tag renaissance-movie-lens-jafra-v0.16.1 \
  --force-build \
  --set BENCHMARKS=movie-lens \
  --set 'RENAISSANCE_ARGS=-c jafra-stress -r 1 --scratch-base /tmp/renaissance-scratch' \
  --set 'JAVA_OPTS=-Xms1g -Xmx2g'
```

Select other benchmarks / JVM options:

```bash
./scripts/deploy.sh --target kind --benchmark renaissance \
  --set BENCHMARKS=scala-kmeans \
  --set 'RENAISSANCE_ARGS=-r 2 --scratch-base /tmp/renaissance-scratch' \
  --set 'JAVA_OPTS=-Xms1g -Xmx2g'
```

## Jafra configuration (workload)

The Job Pod template sets:

```yaml
labels:
  jafra.io/enabled: "true"
  jafra.io/mode: "continuous"
annotations:
  jafra.io/containers: "renaissance"
  jafra.io/loop: "1m"          # shorter than controller default 5m
  jafra.io/jfrsync: "default"
```

The mutating webhook injects async-profiler and writes JFRs to `/jfr-data/profile-%n.jfr`.

Heap / tuning uses `JAVA_OPTS` so Jafra can own `JAVA_TOOL_OPTIONS`.

## Collect JFR

After the Pod is Running (and preferably after at least one `jafra.io/loop` period):

```bash
./scripts/collect-jfr.sh --benchmark renaissance
```

Files land under `artifacts/jfr/`.

## Cleanup

```bash
./scripts/deploy.sh --target kind --benchmark renaissance --cleanup
# or
./scripts/cleanup.sh --target kind --benchmark renaissance
```

Removes only resources labeled for this project / benchmark, and the project image tag from Kind.

## OpenShift

```bash
./scripts/deploy.sh --target openshift --benchmark renaissance
```

Currently exits with an unsupported message. See [`k8s/openshift/README.md`](k8s/openshift/README.md).

## Configuration

| File | Purpose |
|------|---------|
| [`config/defaults.env`](config/defaults.env) | Registry, namespace, Kind cluster name |
| [`benchmarks/renaissance/benchmark.env`](benchmarks/renaissance/benchmark.env) | Version, defaults, resources |
| `config/local.env` | Optional local overrides (gitignored) |

## Kind vs `imagePullPolicy`

Kind deploys use `imagePullPolicy: IfNotPresent` because images are loaded with
`kind load`. Stale Kind images are handled by explicit remove → load → verify
in `scripts/lib/images.sh`, not by `Always`.

Registry-backed targets (future OpenShift) should use `Always` or digests.

## Troubleshooting

| Symptom | What to check |
|---------|----------------|
| Stale Kind image | Redeploy with `--force-build`; script removes/reloads the tag |
| Pod image mismatch | Deploy prints local / Kind / Pod image IDs |
| Image pull errors on Kind | Confirm `kind load` succeeded; keep `IfNotPresent` |
| Renaissance OOM | Raise `MEMORY_LIMIT` / `JAVA_OPTS` via `--set` |
| JFR missing | Confirm `jafra.io/injected=true`; wait for `jafra.io/loop`; ensure controller is ready |
| Jafra not detecting Pod | Labels/annotations must be on the **Pod template**; container name must match annotation |
| Webhook missing | Install Jafra first; deploy script checks `jafra-system` |
| Short run, only live JFR | Increase run time or keep `jafra.io/loop=1m` and wait for rotation |

## Layout

```text
benchmarks/renaissance/   # Dockerfile, entrypoint, benchmark.env, Job YAML
scripts/                  # deploy.sh, build.sh, collect-jfr.sh, cleanup.sh
scripts/lib/              # shared helpers (generic)
k8s/{base,kind,openshift}/
config/defaults.env
renaissance/              # git submodule (source of truth for the suite)
references/               # READ-ONLY local Jafra clones (gitignored)
```
