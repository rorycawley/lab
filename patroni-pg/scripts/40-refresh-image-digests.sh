#!/usr/bin/env bash
set -euo pipefail

# Refresh the image digests pinned in the Kubernetes manifests and the Compose
# file. Resolves the current digest for each managed tag from the registry,
# then rewrites the in-tree references in place.
#
# Skips the locally-built python-postgres-vault-demo image (we own that build)
# and skips Helm chart references (those are pinned by chart version).

declare -a managed=(
  "hashicorp/vault:1.17.6"
  "nginxinc/nginx-unprivileged:1.27-alpine"
  "postgres:16"
  "busybox:1.36"
)

declare -A files_for_image=(
  ["hashicorp/vault:1.17.6"]="k8s/07-vault-deployment.yaml k8s/09-vault-injector-smoke-pod.yaml"
  ["nginxinc/nginx-unprivileged:1.27-alpine"]="k8s/07-vault-deployment.yaml"
  ["postgres:16"]="docker-compose.yml"
  ["busybox:1.36"]=""
)

resolve_digest() {
  local ref="$1"
  local digest=""
  if digest="$(docker buildx imagetools inspect "$ref" --format '{{.Manifest.Digest}}' 2>/dev/null)"; then
    if [[ -n "$digest" ]]; then
      printf '%s' "$digest"
      return 0
    fi
  fi
  if docker pull --quiet "$ref" >/dev/null 2>&1; then
    if digest="$(docker inspect --format='{{index .RepoDigests 0}}' "$ref" 2>/dev/null | sed -n 's/.*@//p')"; then
      printf '%s' "$digest"
      return 0
    fi
  fi
  return 1
}

for ref in "${managed[@]}"; do
  files="${files_for_image[$ref]:-}"
  if [[ -z "$files" ]]; then
    echo "skip: $ref (no managed manifest references)"
    continue
  fi
  echo "resolving: $ref"
  if ! digest="$(resolve_digest "$ref")"; then
    echo "  warning: failed to resolve digest for $ref; leaving manifest unchanged"
    continue
  fi
  echo "  -> $digest"
  for file in $files; do
    if [[ ! -f "$file" ]]; then
      echo "  skip: $file does not exist"
      continue
    fi
    pinned="${ref}@${digest}"
    perl -i -pe "s|\\b${ref}(?:\\@sha256:[0-9a-f]{64})?\\b|${pinned}|g" "$file"
    echo "  pinned in $file"
  done
done

echo "Image digest refresh complete. Review the diff with: git diff -- k8s/ docker-compose.yml"
