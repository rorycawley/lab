#!/usr/bin/env bash
set -euo pipefail

# Prefetch all container images the demo uses, in parallel. Sequential pulls
# during `make up` cost ~30-60s when images aren't cached; parallel prefetch
# at the start of the chain reduces that to the time of the slowest single
# image. No-op (fast) when images are already in the local cache.

images=(
  "hashicorp/vault:1.17.6"
  "nginxinc/nginx-unprivileged:1.27-alpine"
  "postgres:16"
  "busybox:1.36"
)

echo "Prefetching ${#images[@]} images in parallel..."

pids=()
for image in "${images[@]}"; do
  (
    if docker image inspect "$image" >/dev/null 2>&1; then
      echo "  cached: $image"
    else
      echo "  pulling: $image"
      docker pull --quiet "$image" >/dev/null 2>&1 \
        && echo "  done:   $image" \
        || echo "  warn: failed to pull $image (will retry on demand)"
    fi
  ) &
  pids+=($!)
done

for pid in "${pids[@]}"; do
  wait "$pid"
done

echo "Prefetch complete."
