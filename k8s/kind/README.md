# Kind notes

Kind-specific behavior lives in `scripts/lib/images.sh` and `scripts/deploy.sh`:

1. Detect cluster (`KIND_CLUSTER_NAME`, default `jafra`).
2. Build image from source when missing or `--force-build`.
3. Remove stale image from the Kind node when forcing rebuild or ID mismatch.
4. `kind load docker-image`.
5. Verify the image is present on the node.
6. Apply Job with `imagePullPolicy: IfNotPresent`.

`imagePullPolicy: Always` is **not** used for Kind local tags: Kubernetes would attempt a registry pull and can miss or fight the locally loaded image. Stale-image safety is handled by explicit Kind remove/load/verify plus unique version tags (`renaissance_v0.16.1`).
