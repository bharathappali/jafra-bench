# Base Kubernetes notes

Benchmark Jobs are rendered from `benchmarks/<name>/k8s/` templates.

Shared conventions:

- Namespace label: `app.kubernetes.io/part-of=jafra-bench`
- Workload labels: `jafra-bench.benchmark=<name>`
- Jafra opt-in on Pod template:
  - `jafra.io/enabled=true`
  - `jafra.io/mode=continuous`
  - `jafra.io/containers=<container-name>`
