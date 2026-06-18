#!/bin/bash
# =============================================================
# release — tag a version and print the Homebrew formula fields
# -------------------------------------------------------------
# Tags the current commit, pushes the tag, then prints the url +
# sha256 to paste into Formula/iyf.rb.
#
#   ./release.sh v1.0.0
#   ./release.sh v1.0.0 --no-push   # tag locally only
# =============================================================
set -euo pipefail

version=${1:-}
push=1
[[ "${2:-}" == "--no-push" ]] && push=0

[[ -n "$version" ]] || { echo "usage: release.sh vX.Y.Z [--no-push]" >&2; exit 1; }
[[ "$version" == v* ]] || { echo "release: version must start with 'v' (e.g. v1.0.0)" >&2; exit 1; }

repo="janacm/iyf"
tarball="https://github.com/${repo}/archive/refs/tags/${version}.tar.gz"

if git rev-parse "$version" >/dev/null 2>&1; then
  echo "release: tag $version already exists" >&2
else
  git tag -a "$version" -m "$version"
  echo "Tagged $version"
fi

if [[ "$push" == 1 ]]; then
  git push origin "$version"
  echo "Pushed tag $version"
else
  echo "Skipped push (--no-push). Push later with: git push origin $version"
fi

echo
echo "Computing sha256 for the GitHub release tarball..."
echo "(GitHub may take a few seconds to generate the tarball after a push.)"
sha=$(curl -fsSL --retry 5 --retry-delay 2 "$tarball" | shasum -a 256 | awk '{print $1}')

echo
echo "Paste these into Formula/iyf.rb:"
echo "  url    \"$tarball\""
echo "  sha256 \"$sha\""
