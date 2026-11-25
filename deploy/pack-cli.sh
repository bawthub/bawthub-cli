#!/usr/bin/env bash
# Package one committed source revision without Docker or a registry login.
# Usage: bash deploy/pack-cli.sh FULL_COMMIT_SHA OUTPUT_DIRECTORY
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
git_at() { git -C "$repo" "$@"; }
sha="${1:-}"
[[ $# == 2 && "$sha" =~ ^[0-9a-f]{40}$ && "$(git_at cat-file -t "$sha")" == commit ]] || {
  printf 'Usage: %s FULL_COMMIT_SHA OUTPUT_DIRECTORY\n' "$0" >&2; exit 2;
}
[[ "$(git_at rev-parse --is-shallow-repository)" == false ]] || {
  printf 'Full Git history is needed to recognize previously shipped pins.\n' >&2; exit 2;
}
mkdir -p -- "$2"
out="$(cd "$2" && pwd -P)"
stage="$(mktemp -d)"
trap 'rm -rf -- "$stage"' EXIT
mkdir "$stage/release"
git_at show "$sha:deploy/cli/package.json" > "$stage/package.json"
git_at show "$sha:deploy/cli/bh.cjs" > "$stage/bh.cjs"
git_at show "$sha:deploy/bh" > "$stage/bh.sh"
git_at show "$sha:deploy/bh-status.cjs" > "$stage/bh-status.cjs"
git_at show "$sha:deploy/bh-version.cjs" > "$stage/bh-version.cjs"
git_at show "$sha:deploy/bh-chat.cjs" > "$stage/bh-chat.cjs"
git_at show "$sha:deploy/install.sh" > "$stage/release/install.sh"
chmod 755 "$stage/bh.cjs" "$stage/bh.sh" "$stage/release/install.sh"
# A public CLI package must not include the upstream repository or host tooling.
# Include optional runtime overlays and helpers only when present at this revision.
paths=(LICENSE deploy/bh deploy/bh-status.cjs deploy/bh-version.cjs deploy/bh-chat.cjs deploy/cli/package.json
  deploy/install.sh deploy/bootstrap.sh deploy/tenant.env.example)
while IFS= read -r path; do
  paths+=("$path")
done < <(git_at ls-tree -r --name-only "$sha" -- deploy/compose deploy/traefik/dynamic/routes.yml \
  deploy/house_reconcile.py deploy/house_reconcile_edge.py deploy/house_reconcile_host.py)
git_at show "$sha:LICENSE" > "$stage/LICENSE"
git_at archive --format=tar "$sha" -- "${paths[@]}" > "$stage/release/source.tar"
printf 'SOURCE_COMMIT=%s\n' "$sha" > "$stage/release/release.txt"
{ git_at log --format= -p "$sha" -- deploy/tenant.env.example; git_at show "$sha:deploy/tenant.env.example"; } \
  | sed -n -E 's/^[-+ ]?#?([A-Z][A-Z0-9_]*_IMAGE_REF=[^[:space:]]+).*$/\1/p' | LC_ALL=C sort -u > "$stage/release/published-pins"
(
  cd "$stage/release"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum install.sh release.txt source.tar published-pins
  else
    shasum -a 256 install.sh release.txt source.tar published-pins
  fi > SHA256SUMS
)
(cd "$stage" && npm pack --ignore-scripts --offline --pack-destination "$out")
