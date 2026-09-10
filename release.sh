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
# =============================================================
set -euo pipefail

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

repo="janacm/ada"
tarball="https://github.com/${repo}/archive/refs/tags/${version}.tar.gz"
dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
formula="$dir/Formula/ada.rb"
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

if git -C "$dir" rev-parse "$version" >/dev/null 2>&1; then
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
sha=$(curl -fsSL --retry 5 --retry-delay 2 "$tarball" | shasum -a 256 | awk '{print $1}')
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
  git -C "$dir" push -q origin main
  echo "Committed and pushed the formula bump to main"
fi

echo
echo "Released $version. Verify with:"
echo "  brew update && brew upgrade ada     # existing installs"
echo "  brew install janacm/ada/ada         # fresh install"
echo "  brew style Formula/ada.rb && brew test janacm/ada/ada"
