# OpenShift target (stub)

OpenShift deployment is **not implemented** in this repository yet.

The CLI accepts `--target openshift` and exits with a clear unsupported message.

## Differences from Kind (for a future implementation)

| Concern | Kind | OpenShift |
|---------|------|-----------|
| Image delivery | `kind load docker-image` | Push to OpenShift internal registry or an external registry the cluster can pull |
| Stale images | Explicit remove + reload on the Kind node | Registry digests / unique tags + `imagePullPolicy: Always` |
| `imagePullPolicy` | `IfNotPresent` (local load) | `Always` (or pin by digest) |
| SCC | N/A | Benchmark Pods using `emptyDir` + Jafra injection do **not** need privileged SCC. The **jafra-agent** DaemonSet (platform) uses a custom `jafra-agent` SCC — install that with the Jafra platform, not this repo. |
| Webhooks / certs | cert-manager + Jafra controller (pre-installed) | Same; ensure webhook is allowed by OpenShift admission |

## Workload YAML reuse

The Job template under `benchmarks/<name>/k8s/` is generic Kubernetes and should be reusable on OpenShift once image push/pull is wired. Prefer keeping OpenShift-specific overlays in this directory when implemented.
