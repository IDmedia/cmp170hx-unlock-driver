#!/bin/bash
# Opens a merge request that adds new cmpunlocker tags to versions.json, so a new tag is reviewed once
# and then built for every kernel by the next pipeline. Does nothing if every tag is listed or the
# branch for this change already exists.
# Usage: ci/check-upstream.sh      Needs: git, jq, curl, CI_PUSH_TOKEN (project access token with write_repository).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

latest="$(curl -fsSL "https://api.github.com/repos/amoghmunikote/cmpunlocker/tags?per_page=100" \
  | jq -r '.[].name' | grep -E '^v[0-9]+(\.[0-9]+)*$' | sort -V | tail -1)"
[ -n "$latest" ] || { echo "no cmpunlocker tags found"; exit 1; }
newest_listed="$(jq -r '.cmpunlocker[]' versions.json | sort -V | tail -1)"
if [ "$(printf '%s\n%s\n' "$latest" "$newest_listed" | sort -V | tail -1)" = "$newest_listed" ]; then
  echo "versions.json is up to date (newest cmpunlocker tag: $latest)"; exit 0
fi

branch="cmpunlocker-$latest"
remote="https://oauth2:${CI_PUSH_TOKEN:?}@${CI_SERVER_HOST}/${CI_PROJECT_PATH}.git"
if git ls-remote --exit-code --heads "$remote" "$branch" >/dev/null; then
  echo "branch $branch already exists, merge request pending"; exit 0
fi

drivers="$(curl -fsSL "https://raw.githubusercontent.com/amoghmunikote/cmpunlocker/refs/tags/$latest/driver/VERSION" \
  | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | paste -sd, -)"
jq --arg t "$latest" '.cmpunlocker += [$t]' versions.json > versions.json.tmp && mv versions.json.tmp versions.json
git -c user.name="CI" -c user.email="ci@${CI_SERVER_HOST}" commit -qm "Build cmpunlocker $latest (drivers: $drivers)" versions.json
git push -o merge_request.create -o merge_request.remove_source_branch \
  -o merge_request.title="Build cmpunlocker $latest" \
  -o merge_request.description="cmpunlocker $latest supports drivers: $drivers. Merging builds it for every supported kernel. Review the upstream changes first: https://github.com/amoghmunikote/cmpunlocker/releases/tag/$latest" \
  "$remote" "HEAD:refs/heads/$branch"
