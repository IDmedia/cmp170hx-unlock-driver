#!/bin/bash
# Prepares the tag <tag> for a GitHub release:
# - creates it in GitLab at this pipeline's commit unless it exists. The push mirror deletes tags that exist
#   only on GitHub, which turns their releases into drafts; a tag in GitLab is carried by the mirror instead.
# - deletes draft releases with that tag (left behind by such a deletion). gh finds drafts by tag, so a
#   draft would otherwise be updated in place of a published release.
# Usage: ci/prepare-release.sh <tag>      Needs: gh (GH_TOKEN, GH_REPO), git, CI_PUSH_TOKEN (write_repository).
set -euo pipefail
TAG="${1:?tag}"
remote="https://oauth2:${CI_PUSH_TOKEN:?}@${CI_SERVER_HOST}/${CI_PROJECT_PATH}.git"
if ! git ls-remote --exit-code --tags "$remote" "refs/tags/$TAG" >/dev/null; then
  git push -q "$remote" "${CI_COMMIT_SHA:?}:refs/tags/$TAG"
  echo "created tag $TAG in GitLab at $CI_COMMIT_SHA"
fi
for id in $(gh api --paginate "repos/$GH_REPO/releases" --jq ".[] | select(.draft and .tag_name == \"$TAG\") | .id"); do
  gh api -X DELETE "repos/$GH_REPO/releases/$id" >/dev/null
  echo "deleted draft release $TAG ($id)"
done
