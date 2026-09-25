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
#   ./release.sh --prs-since-release   # PR numbers merged since the formula's
#                                      # version
#   ./release.sh --auto minor|major    # what the release workflow runs: pick
#                                      # the version and release it (see below)
#
# Because the two steps are separate pushes, a release can stop halfway: the
# tag is on GitHub but main never got the formula bump. Re-running with the same
# version finishes it, and --next returns that version again instead of
# skipping past it.
# =============================================================
set -euo pipefail

dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
formula="$dir/Formula/ada.rb"

# The newest stable tag (vX.Y or vX.Y.Z) reachable from HEAD. A pre-release
# such as v1.0-rc1 version-sorts ahead of v0.9, and a tag on another branch is
# not a release of main, so neither may set the next number.
__latest_stable_tag() {
  git -C "$dir" tag --list 'v*' --merged HEAD --sort=-v:refname \
    | grep -E '^v[0-9]+\.[0-9]+(\.[0-9]+)?$' | head -1 || true
}

# True when the local tag $1 is the one already on GitHub, i.e. it was
# published and its tarball may already be in someone's cache.
__tag_is_published() {
  local remote
  remote=$(git -C "$dir" ls-remote --tags origin "refs/tags/$1" | awk '{print $1}')
  [[ -n "$remote" && "$remote" == "$(git -C "$dir" rev-parse "refs/tags/$1")" ]]
}

# True when the formula on this checkout already installs $1's tarball.
__formula_points_at() {
  grep -qF "refs/tags/$1.tar.gz\"" "$formula"
}

# The version the formula installs now (v0.4), or nothing.
__formula_version() {
  sed -nE 's|^[[:space:]]*url "[^"]*/refs/tags/(v[^"]*)\.tar\.gz"|\1|p' "$formula" | head -1
}

# True when version $1 is newer than $2, comparing vX.Y[.Z] numerically.
__version_gt() {
  local a b i
  IFS=. read -r -a a <<<"${1#v}"
  IFS=. read -r -a b <<<"${2#v}"
  for i in 0 1 2; do
    (( 10#${a[i]:-0} > 10#${b[i]:-0} )) && return 0
    (( 10#${a[i]:-0} < 10#${b[i]:-0} )) && return 1
  done
  return 1
}

if [[ "${1:-}" == --next ]]; then
  bump=${2:-}
  [[ "$bump" == minor || "$bump" == major ]] \
    || { echo "usage: release.sh --next minor|major" >&2; exit 1; }
  [[ -f "$formula" ]] || { echo "release: missing $formula" >&2; exit 1; }
  last=$(__latest_stable_tag)
  current=$(__formula_version)
  # Only a PUBLISHED tag NEWER than what the formula installs can be an
  # unfinished release. An older one is history ("finishing" it would
  # downgrade), and a local-only one was never released.
  if [[ -n "$last" ]] && ! __formula_points_at "$last" &&
     { [[ -z "$current" ]] || __version_gt "$last" "$current"; } &&
     __tag_is_published "$last"; then
    echo "release: $last is tagged but the formula never pointed at it; finishing $last" >&2
    echo "$last"
    exit 0
  fi
  # Count from what the formula installs; the tags only matter when it names
  # no version at all.
  base=${current:-$last}
  IFS=. read -r maj min _ <<<"${base#v}"
  maj=${maj:-0} min=${min:-0}
  if [[ "$bump" == major ]]; then maj=$((maj + 1)); min=0; else min=$((min + 1)); fi
  echo "v$maj.$min"
  exit 0
fi

# --auto <bump>: the release workflow's whole job, here so bats can cover it.
#   1. The bump is major if the triggering PR asked for it OR any PR merged
#      since the formula's version is labelled release:major (gh reads the
#      labels). GitHub keeps one pending run per concurrency group, so a queued
#      release:major run can be replaced by a later release:minor one.
#   2. --next picks the version, and it is released.
#   3. If that was a tag an earlier run pushed but never finished, only its
#      older commit shipped. Release the commit this job tested as well, but
#      only when nothing but our own formula bump sits on top of it: newer
#      commits from a concurrent merge are untested, and the next labelled
#      merge releases them.
if [[ "${1:-}" == --auto ]]; then
  trigger=${2:-}
  [[ "$trigger" == minor || "$trigger" == major ]] \
    || { echo "usage: release.sh --auto minor|major" >&2; exit 1; }
  self="${BASH_SOURCE[0]}"
  tested=$(git -C "$dir" rev-parse HEAD)
  __pick() {
    local bump=$trigger pr
    for pr in $("$self" --prs-since-release); do
      if gh pr view "$pr" --json labels --jq '.labels[].name' 2>/dev/null | grep -qx 'release:major'; then
        echo "release: #$pr asked for a major release" >&2
        bump=major
      fi
    done
    "$self" --next "$bump"
  }
  version=$(__pick)
  "$self" "$version"
  if [[ "$(git -C "$dir" rev-parse "refs/tags/$version^{commit}")" != "$tested" ]]; then
    if [[ "$(git -C "$dir" rev-parse -q --verify HEAD~1 || true)" == "$tested" ]]; then
      echo "release: finished the stranded $version; now releasing the tested main"
      version=$(__pick)
      "$self" "$version"
    else
      echo "release: main moved during the release; its newer commits ship with the next labelled merge"
    fi
  fi
  exit 0
fi

# Every PR merged since the formula's version, from merge-commit subjects
# ("Merge pull request #12 from ...") and squash subjects ("Title (#12)").
# --auto reads their labels.
if [[ "${1:-}" == --prs-since-release ]]; then
  [[ -f "$formula" ]] || { echo "release: missing $formula" >&2; exit 1; }
  current=$(__formula_version)
  range=HEAD
  if [[ -n "$current" ]] && git -C "$dir" rev-parse -q --verify "refs/tags/$current" >/dev/null; then
    range="$current..HEAD"
  fi
  git -C "$dir" log --format=%s "$range" \
    | sed -nE -e 's/^Merge pull request #([0-9]+) .*/\1/p' -e 's/.*\(#([0-9]+)\)$/\1/p' \
    | sort -un
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
  elif __tag_is_published "$version" && git -C "$dir" merge-base --is-ancestor "$tagged" HEAD; then
    if __formula_points_at "$version"; then
      echo "release: $version is already released and the formula points at it"
      exit 0
    fi
    current=$(__formula_version)
    if [[ -n "$current" ]] && ! __version_gt "$version" "$current"; then
      echo "release: $version is older than the formula's $current; refusing to downgrade" >&2
      exit 1
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
