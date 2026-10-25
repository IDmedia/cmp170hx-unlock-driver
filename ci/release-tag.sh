#!/bin/bash
# Creates the tag <tag> in GitLab at this pipeline's commit unless it exists. Every GitHub release tag must
# also exist in GitLab: the push mirror deletes tags that exist only on GitHub, which turns their
# releases into drafts. Called before a GitHub release is created; the release then uses the same commit.
# Usage: ci/release-tag.sh <tag>      Needs: git, CI_PUSH_TOKEN (project access token with write_repository).
set -euo pipefail
TAG="${1:?tag}"
remote="https://oauth2:${CI_PUSH_TOKEN:?}@${CI_SERVER_HOST}/${CI_PROJECT_PATH}.git"
if git ls-remote --exit-code --tags "$remote" "refs/tags/$TAG" >/dev/null; then exit 0; fi
git push -q "$remote" "${CI_COMMIT_SHA:?}:refs/tags/$TAG"
echo "created tag $TAG in GitLab at $CI_COMMIT_SHA"
