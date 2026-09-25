#!/bin/bash
# =============================================================
# release — cut a version and update the Homebrew formula
# -------------------------------------------------------------
# Because this repo doubles as its own Homebrew tap, `brew` reads
# Formula/ada.rb from the TIP OF main — never from inside the tagged
# tarball. And a tag's tarball can't contain its own sha256. So a
# release is inherently two steps: tag/push, then commit the formula
# pointing at that tag. This script does both so they can't drift.
#
#   ./release.sh v1.0.0
#   ./release.sh v1.0.0 --no-push      # tag locally only, change nothing else
#   ./release.sh v1.0.0 --no-formula   # tag + push, print fields, don't commit
#   ./release.sh --next minor|major    # print the version to cut next, and exit
# =============================================================
set -euo pipefail

repo="janacm/ada"
dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
formula="$dir/Formula/ada.rb"

# The version a release:minor or release:major merge should cut. "Previous" is
# the version the formula points at, which is what is actually released: a tag
# pushed by a run whose formula push then failed is not a release, and counting
# it would skip a version. Without a version in the formula, the newest stable
# tag, matched like the formula's livecheck regex so v1.0-rc1 can't outrank v0.4.
if [[ "${1:-}" == --next ]]; then
  bump=${2:-}
  [[ "$bump" == minor || "$bump" == major ]] || { echo "usage: release.sh --next minor|major" >&2; exit 1; }
  stable='^v[0-9]+(\.[0-9]+)+$'
  previous=$(sed -n 's|^[[:space:]]*url[[:space:]]*"[^"]*/archive/refs/tags/\([^"/]*\)\.tar\.gz".*|\1|p' "$formula" 2>/dev/null | head -1 || true)
  if ! [[ "$previous" =~ $stable ]]; then
    previous=$(git -C "$dir" tag --list 'v[0-9]*' --sort=-v:refname | grep -E "$stable" | head -1 || true)
  fi
  IFS=. read -r maj min _ <<<"${previous#v}"
  maj=${maj:-0} min=${min:-0}
  if [[ "$bump" == major ]]; then maj=$((10#$maj + 1)); min=0; else min=$((10#$min + 1)); fi
  echo "v$maj.$min"
  exit 0
fi

version=${1:-}
push=1
update_formula=1
for arg in "${@:2}"; do
  case "$arg" in
    --no-push)    push=0 ;;
    --no-formula) update_formula=0 ;;
    *) echo "release: unknown flag '$arg'" >&2; exit 1 ;;
  esac
done

[[ -n "$version" ]] || { echo "usage: release.sh vX.Y.Z [--no-push] [--no-formula]" >&2; exit 1; }
[[ "$version" == v* ]] || { echo "release: version must start with 'v' (e.g. v1.0.0)" >&2; exit 1; }

tarball="https://github.com/${repo}/archive/refs/tags/${version}.tar.gz"
[[ -f "$formula" ]] || { echo "release: missing $formula" >&2; exit 1; }

# A dirty tree means the tag would not describe what gets released.
if [[ -n "$(git -C "$dir" status --porcelain)" ]]; then
  echo "release: working tree is dirty — commit or stash first" >&2
  exit 1
fi

branch=$(git -C "$dir" rev-parse --abbrev-ref HEAD)
if [[ "$branch" != "main" ]]; then
  echo "release: on '$branch', not main. The tap serves the formula from main's tip." >&2
  exit 1
fi

# The tarball is built from the tag, but users also get the formula from main —
# so main must already be pushed or the two will describe different code.
git -C "$dir" fetch --quiet origin main
if [[ "$(git -C "$dir" rev-parse HEAD)" != "$(git -C "$dir" rev-parse origin/main)" ]]; then
  echo "release: HEAD differs from origin/main — push main before tagging" >&2
  exit 1
fi

if tagged=$(git -C "$dir" rev-parse -q --verify "refs/tags/$version^{commit}"); then
  # Re-running is supported, but only for a tag that still describes main: HEAD
  # itself, or HEAD's parent when HEAD is this release's own formula bump.
  head=$(git -C "$dir" rev-parse HEAD)
  parent=$(git -C "$dir" rev-parse -q --verify HEAD~1 || true)
  if [[ "$tagged" != "$head" ]] &&
     ! [[ "$tagged" == "$parent" && "$(git -C "$dir" log -1 --format=%s)" == "Homebrew: point formula at $version" ]]; then
    echo "release: tag $version points at ${tagged:0:12}, not HEAD (${head:0:12})." >&2
    echo "  Delete it (git tag -d $version && git push origin :refs/tags/$version) or pick a new version." >&2
    exit 1
  fi
  echo "release: tag $version already exists"
else
  git -C "$dir" tag -a "$version" -m "$version"
  echo "Tagged $version"
fi

if [[ "$push" == 0 ]]; then
  echo "Skipped push (--no-push). Push later with: git push origin $version"
  echo
  echo "Skipping sha256: the GitHub tarball doesn't exist until the tag is pushed."
  echo "Once pushed, finish the release with: ./release.sh $version"
  exit 0
fi

git -C "$dir" push origin "$version"
echo "Pushed tag $version"

echo
echo "Computing sha256 for the GitHub release tarball..."
echo "(GitHub may take a few seconds to generate the tarball after a push.)"
sha=$(curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors "$tarball" | shasum -a 256 | awk '{print $1}')
[[ ${#sha} == 64 ]] || { echo "release: got a bad sha256 ('$sha')" >&2; exit 1; }

if [[ "$update_formula" == 0 ]]; then
  echo
  echo "Paste these into Formula/ada.rb (--no-formula):"
  echo "  url    \"$tarball\""
  echo "  sha256 \"$sha\""
  exit 0
fi

python3 - "$formula" "$tarball" "$sha" <<'PY'
import pathlib, re, sys
path, url, sha = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
text = path.read_text()
text, n_url = re.subn(r'^(\s*url\s+)"[^"]*"', lambda m: f'{m.group(1)}"{url}"', text, count=1, flags=re.M)
text, n_sha = re.subn(r'^(\s*sha256\s+)"[^"]*"', lambda m: f'{m.group(1)}"{sha}"', text, count=1, flags=re.M)
if n_url != 1 or n_sha != 1:
    raise SystemExit(f"release: could not rewrite url/sha256 in {path} (url={n_url} sha={n_sha})")
path.write_text(text)
PY
echo "Updated $formula"

if [[ -z "$(git -C "$dir" status --porcelain -- Formula/ada.rb)" ]]; then
  echo "Formula already pointed at $version — nothing to commit."
else
  git -C "$dir" add Formula/ada.rb
  git -C "$dir" commit -q -m "Homebrew: point formula at $version"
  if ! git -C "$dir" push -q origin main; then
    # main moved after the check above (another merge landed while the tarball
    # downloaded). The tag is pushed but no formula names it, so it is not a
    # release. Take it back, so a re-run cuts the same version from the new
    # main instead of counting this tag as released and skipping a version.
    # The reset drops only the commit made just above: the tree was clean.
    git -C "$dir" reset -q --hard HEAD~1
    if ! git -C "$dir" push -q origin ":refs/tags/$version"; then
      echo "release: could not delete the pushed tag; do it with: git push origin :refs/tags/$version" >&2
    fi
    git -C "$dir" tag -d "$version" >/dev/null
    echo "release: pushing the formula bump to main failed (did main move?)." >&2
    echo "  Removed tag $version; re-run to release $version from the new main." >&2
    exit 1
  fi
  echo "Committed and pushed the formula bump to main"
fi

echo
echo "Released $version. Verify with:"
echo "  brew update && brew upgrade ada     # existing installs"
echo "  brew install janacm/ada/ada         # fresh install"
echo "  brew style Formula/ada.rb && brew test janacm/ada/ada"
