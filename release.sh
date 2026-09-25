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
#   ./release.sh --next minor|major    # print the version to release next
#
# Because the two steps are separate pushes, a release can stop halfway: the
# tag is on GitHub but main never got the formula bump. Re-running with the same
# version finishes it, and --next returns that version again instead of
# skipping past it.
# =============================================================
set -euo pipefail

dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
formula="$dir/Formula/ada.rb"

# The newest stable tag (vX.Y or vX.Y.Z). A pre-release such as v1.0-rc1
# version-sorts ahead of v0.9, so it must never be the base for the next number.
__latest_stable_tag() {
  git -C "$dir" tag --list 'v*' --sort=-v:refname \
    | grep -E '^v[0-9]+\.[0-9]+(\.[0-9]+)?$' | head -1 || true
}

# True when the formula on this checkout already installs $1's tarball.
__formula_points_at() {
  grep -qF "refs/tags/$1.tar.gz\"" "$formula"
}

if [[ "${1:-}" == --next ]]; then
  bump=${2:-}
  [[ "$bump" == minor || "$bump" == major ]] \
    || { echo "usage: release.sh --next minor|major" >&2; exit 1; }
  [[ -f "$formula" ]] || { echo "release: missing $formula" >&2; exit 1; }
  last=$(__latest_stable_tag)
  if [[ -n "$last" ]] && ! __formula_points_at "$last"; then
    echo "release: $last is tagged but the formula never pointed at it; finishing $last" >&2
    echo "$last"
    exit 0
  fi
  IFS=. read -r maj min _ <<<"${last#v}"
  maj=${maj:-0} min=${min:-0}
  if [[ "$bump" == major ]]; then maj=$((maj + 1)); min=0; else min=$((min + 1)); fi
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

repo="janacm/ada"
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

# True when the local tag is the one already on GitHub, i.e. it was published
# and its tarball may already be in someone's cache.
__tag_is_published() {
  local remote
  remote=$(git -C "$dir" ls-remote --tags origin "refs/tags/$version" | awk '{print $1}')
  [[ -n "$remote" && "$remote" == "$(git -C "$dir" rev-parse "refs/tags/$version")" ]]
}

if tagged=$(git -C "$dir" rev-parse -q --verify "refs/tags/$version^{commit}"); then
  # Re-running is supported for a tag that still describes main: HEAD itself,
  # or HEAD's parent when HEAD is this release's own formula bump.
  head=$(git -C "$dir" rev-parse HEAD)
  parent=$(git -C "$dir" rev-parse -q --verify HEAD~1 || true)
  if [[ "$tagged" == "$head" ]] ||
     [[ "$tagged" == "$parent" && "$(git -C "$dir" log -1 --format=%s)" == "Homebrew: point formula at $version" ]]; then
    echo "release: tag $version already exists"
  # A published tag that main has since moved past: either a release that
  # stopped before its formula bump (finish it), or one that finished and whose
  # bump was rebased onto later work (nothing to do). Either way the tarball is
  # the tagged code, and only the formula on main is missing or already right.
  elif __tag_is_published && git -C "$dir" merge-base --is-ancestor "$tagged" HEAD; then
    if __formula_points_at "$version"; then
      echo "release: $version is already released and the formula points at it"
      exit 0
    fi
    echo "release: finishing $version: the tag is published but the formula never pointed at it"
  else
    echo "release: tag $version points at ${tagged:0:12}, not HEAD (${head:0:12})." >&2
    echo "  Delete it (git tag -d $version) or pick a new version." >&2
    exit 1
  fi
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
  # The tag is already public, so main moving during the tarball download must
  # not strand it. The bump touches only the formula: replay it on the new main
  # and push again. A conflict means someone else changed the formula; stop.
  #
  # Giving up drops the unpushed bump and puts main back on origin/main, so the
  # suggested re-run passes the HEAD == origin/main check and finishes the tag.
  # --keep refuses rather than discard anything but that one commit (the tree
  # was clean when this started).
  __give_up() {
    git -C "$dir" fetch -q origin main || true
    git -C "$dir" reset -q --keep origin/main || true
    echo "release: $1; re-run ./release.sh $version to finish" >&2
    exit 1
  }
  for attempt in 1 2 3; do
    git -C "$dir" push -q origin main && break
    (( attempt < 3 )) || __give_up "could not push the formula bump"
    echo "release: main moved; replaying the formula bump on origin/main"
    git -C "$dir" fetch -q origin main
    if ! git -C "$dir" rebase -q origin/main; then
      git -C "$dir" rebase --abort 2>/dev/null || true
      __give_up "the formula bump conflicts with origin/main"
    fi
  done
  echo "Committed and pushed the formula bump to main"
fi

echo
echo "Released $version. Verify with:"
echo "  brew update && brew upgrade ada     # existing installs"
echo "  brew install janacm/ada/ada         # fresh install"
echo "  brew style Formula/ada.rb && brew test janacm/ada/ada"
