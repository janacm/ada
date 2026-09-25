#!/usr/bin/env bats
# Tests for release.sh — tag, push, and bump Formula/ada.rb to the new tarball.
#
# release.sh finds its checkout from its own path, so each test builds a
# throwaway repo with a symlink to the real script, a copy of the real formula,
# and a local bare repo as `origin`. Pushes land in that bare repo, and curl is
# stubbed to serve fixed bytes for the tarball, so nothing reaches GitHub.

setup() {
  load test_helper
  setup_common
  WORK="$BATS_TEST_TMPDIR/work"
  ORIGIN="$BATS_TEST_TMPDIR/origin.git"
  git init -q --bare -b main "$ORIGIN"
  git init -q -b main "$WORK"
  git -C "$WORK" config user.name "Release Test"
  git -C "$WORK" config user.email "release@example.invalid"
  mkdir -p "$WORK/Formula"
  ln -s "$REPO_ROOT/release.sh" "$WORK/release.sh"
  cp "$REPO_ROOT/Formula/ada.rb" "$WORK/Formula/ada.rb"
  git -C "$WORK" add -A
  git -C "$WORK" commit -q -m "initial"
  git -C "$WORK" remote add origin "$ORIGIN"
  git -C "$WORK" push -q origin main
  RELEASE="$WORK/release.sh"

  # curl stub: the "tarball" is a fixed string, so its sha256 is known.
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat > "$BATS_TEST_TMPDIR/bin/curl" <<'SH'
#!/bin/bash
[ -n "${STUB_CURL_FAIL:-}" ] && exit 22
# Someone merges to main while the release waits on GitHub's tarball, i.e.
# after release.sh checked HEAD and pushed the tag, before the formula push.
if [ -n "${STUB_CURL_ADVANCE:-}" ]; then
  other="$BATS_TEST_TMPDIR/other"
  git clone -q "$STUB_CURL_ADVANCE" "$other" 2>/dev/null
  git -C "$other" -c user.name=o -c user.email=o@example.invalid \
    commit -q --allow-empty -m "concurrent work"
  [ -n "${STUB_CURL_ADVANCE_FORMULA:-}" ] && {
    sed -i '' 's|^  url ".*"|  url "https://example.invalid/other.tar.gz"|' "$other/Formula/ada.rb"
    git -C "$other" -c user.name=o -c user.email=o@example.invalid commit -q -am "someone edits the formula"
  }
  git -C "$other" push -q origin main
  unset STUB_CURL_ADVANCE
fi
printf 'fake tarball for %s' "${!#}"
SH
  chmod +x "$BATS_TEST_TMPDIR/bin/curl"
  # gh stub for --auto: `gh pr view <n> ...` prints release:major for the PR
  # numbers listed in STUB_GH_MAJOR, and nothing for any other PR.
  cat > "$BATS_TEST_TMPDIR/bin/gh" <<'SH'
#!/bin/bash
[ "$1 $2" = "pr view" ] || exit 1
for n in ${STUB_GH_MAJOR:-}; do [ "$n" = "$3" ] && echo "release:major"; done
echo "enhancement"
SH
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

expected_sha() {
  printf 'fake tarball for %s' "https://github.com/janacm/ada/archive/refs/tags/$1.tar.gz" \
    | shasum -a 256 | awk '{print $1}'
}

@test "no version prints usage and fails" {
  run "$RELEASE"
  assert_failure
  assert_output_contains "usage: release.sh vX.Y.Z"
}

@test "a version without the v prefix is rejected" {
  run "$RELEASE" 1.0.0
  assert_failure
  assert_output_contains "must start with 'v'"
}

@test "an unknown flag is rejected before anything is tagged" {
  run "$RELEASE" v9.9.9 --frobnicate
  assert_failure
  assert_output_contains "unknown flag '--frobnicate'"
  run git -C "$WORK" tag -l v9.9.9
  assert_equal "$output" ""
}

@test "a checkout with no formula is rejected" {
  git -C "$WORK" rm -q Formula/ada.rb
  git -C "$WORK" commit -q -m "drop formula"
  run "$RELEASE" v9.9.9
  assert_failure
  assert_output_contains "missing $WORK/Formula/ada.rb"
}

@test "a dirty tree is rejected" {
  echo "# local edit" >> "$WORK/Formula/ada.rb"
  run "$RELEASE" v9.9.9
  assert_failure
  assert_output_contains "working tree is dirty"
}

@test "a branch other than main is rejected" {
  git -C "$WORK" switch -q -c feature
  run "$RELEASE" v9.9.9
  assert_failure
  assert_output_contains "on 'feature', not main"
}

# The tarball comes from the tag but the formula is read from main's tip, so an
# unpushed main would publish a formula describing different code.
@test "an unpushed main is rejected" {
  git -C "$WORK" commit -q --allow-empty -m "not pushed yet"
  run "$RELEASE" v9.9.9
  assert_failure
  assert_output_contains "HEAD differs from origin/main"
}

@test "--no-push tags locally and changes nothing else" {
  run "$RELEASE" v9.9.9 --no-push
  assert_success
  assert_output_contains "Tagged v9.9.9"
  assert_output_contains "Skipped push (--no-push)"
  run git -C "$WORK" rev-parse v9.9.9^{commit}
  assert_equal "$output" "$(git -C "$WORK" rev-parse HEAD)"
  run git -C "$ORIGIN" tag -l v9.9.9
  assert_equal "$output" ""
  run git -C "$WORK" status --porcelain
  assert_equal "$output" ""
}

@test "a full release tags, pushes, and commits the formula bump to main" {
  run "$RELEASE" v9.9.9
  assert_success
  assert_output_contains "Pushed tag v9.9.9"
  assert_output_contains "Committed and pushed the formula bump to main"
  sha=$(expected_sha v9.9.9)
  assert_file_contains "$WORK/Formula/ada.rb" 'url "https://github.com/janacm/ada/archive/refs/tags/v9.9.9.tar.gz"'
  assert_file_contains "$WORK/Formula/ada.rb" "sha256 \"$sha\""
  # livecheck's `url :stable` must survive: only the first quoted url is rewritten.
  assert_file_contains "$WORK/Formula/ada.rb" "url :stable"
  run git -C "$ORIGIN" log -1 --format=%s main
  assert_equal "$output" "Homebrew: point formula at v9.9.9"
  run git -C "$ORIGIN" tag -l v9.9.9
  assert_equal "$output" "v9.9.9"
}

@test "--no-formula prints the fields instead of committing" {
  run "$RELEASE" v9.9.9 --no-formula
  assert_success
  assert_output_contains 'url    "https://github.com/janacm/ada/archive/refs/tags/v9.9.9.tar.gz"'
  assert_output_contains "sha256 \"$(expected_sha v9.9.9)\""
  run git -C "$WORK" status --porcelain
  assert_equal "$output" ""
  run git -C "$ORIGIN" log -1 --format=%s main
  assert_equal "$output" "initial"
}

# The release workflow re-runs release.sh after a failure, so a second run on
# the tag's own formula-bump commit must succeed without a second commit.
@test "re-running a finished release is a no-op" {
  run "$RELEASE" v9.9.9
  assert_success
  before=$(git -C "$WORK" rev-parse HEAD)
  run "$RELEASE" v9.9.9
  assert_success
  assert_output_contains "tag v9.9.9 already exists"
  assert_output_contains "nothing to commit"
  assert_equal "$(git -C "$WORK" rev-parse HEAD)" "$before"
}

@test "an existing tag that no longer describes main is refused" {
  git -C "$WORK" tag -a v9.9.9 -m v9.9.9
  git -C "$WORK" commit -q --allow-empty -m "later work"
  git -C "$WORK" push -q origin main
  run "$RELEASE" v9.9.9
  assert_failure
  assert_output_contains "tag v9.9.9 points at"
  assert_output_contains "git tag -d v9.9.9"
}

@test "a tarball download failure stops before the formula is touched" {
  export STUB_CURL_FAIL=1
  run "$RELEASE" v9.9.9
  assert_failure
  refute_output_contains "Updated"
  run git -C "$WORK" status --porcelain
  assert_equal "$output" ""
}

@test "a formula with no url/sha256 to rewrite fails loudly" {
  printf 'class Ada < Formula\nend\n' > "$WORK/Formula/ada.rb"
  git -C "$WORK" commit -q -am "gut the formula"
  git -C "$WORK" push -q origin main
  run "$RELEASE" v9.9.9
  assert_failure
  assert_output_contains "could not rewrite url/sha256"
}

# --- --next: the version the release workflow cuts --------------------------

# Tag the current HEAD and point the formula at that tag, as a finished release.
finished_release() {
  git -C "$WORK" tag -a "$1" -m "$1"
  sed -i '' "s|^  url \".*\"|  url \"https://github.com/janacm/ada/archive/refs/tags/$1.tar.gz\"|" "$WORK/Formula/ada.rb"
  git -C "$WORK" commit -q --allow-empty -am "Homebrew: point formula at $1"
}

@test "--next with no tags counts from the formula's version" {
  run "$RELEASE" --next minor
  assert_equal "$output" "v0.5"      # the fixture's formula installs v0.4
  run "$RELEASE" --next major
  assert_equal "$output" "v1.0"
}

@test "--next with no version anywhere starts at v0.1 or v1.0" {
  sed -i '' 's|^  url ".*"|  url "https://example.invalid/ada.tar.gz"|' "$WORK/Formula/ada.rb"
  git -C "$WORK" commit -q -am "formula names no tag"
  run "$RELEASE" --next minor
  assert_equal "$output" "v0.1"
  run "$RELEASE" --next major
  assert_equal "$output" "v1.0"
}

@test "--next bumps the latest finished release" {
  finished_release v0.4
  run "$RELEASE" --next minor
  assert_success
  assert_equal "$output" "v0.5"
  run "$RELEASE" --next major
  assert_equal "$output" "v1.0"
}

@test "--next ignores a pre-release tag that version-sorts ahead" {
  finished_release v0.4
  git -C "$WORK" tag -a v1.0-rc1 -m rc
  run "$RELEASE" --next minor
  assert_equal "$output" "v0.5"
}

@test "--next returns an unfinished release instead of skipping past it" {
  finished_release v0.4
  git -C "$WORK" commit -q --allow-empty -m "more work"
  git -C "$WORK" tag -a v0.5 -m v0.5    # tagged, formula still at v0.4
  git -C "$WORK" push -q origin v0.5
  run "$RELEASE" --next minor
  assert_success
  assert_output_contains "finishing v0.5"
  assert_equal "${lines[${#lines[@]}-1]}" "v0.5"
}

@test "--next rejects anything but minor or major" {
  run "$RELEASE" --next patch
  assert_failure
  assert_output_contains "usage: release.sh --next minor|major"
}

# --- main moving under a release ---------------------------------------------

@test "main moving during the release replays the formula bump instead of stranding the tag" {
  export STUB_CURL_ADVANCE="$ORIGIN"
  tagged=$(git -C "$WORK" rev-parse HEAD)
  run "$RELEASE" v9.9.9
  assert_success
  assert_output_contains "main moved; replaying the formula bump"
  run git -C "$ORIGIN" log --format=%s -2 main
  assert_equal "${lines[0]}" "Homebrew: point formula at v9.9.9"
  assert_equal "${lines[1]}" "concurrent work"
  # the tag still names the code that was checked, not the later merge
  assert_equal "$(git -C "$ORIGIN" rev-parse 'v9.9.9^{commit}')" "$tagged"
}

@test "a finished release whose bump was replayed re-runs as a no-op" {
  export STUB_CURL_ADVANCE="$ORIGIN"
  run "$RELEASE" v9.9.9
  assert_success
  before=$(git -C "$ORIGIN" rev-parse main)
  run "$RELEASE" v9.9.9
  assert_success
  assert_output_contains "already released"
  assert_equal "$(git -C "$ORIGIN" rev-parse main)" "$before"
}

@test "a published tag whose formula bump never landed is finished on re-run" {
  git -C "$WORK" tag -a v9.9.9 -m v9.9.9
  git -C "$WORK" push -q origin v9.9.9
  git -C "$WORK" commit -q --allow-empty -m "later work"
  git -C "$WORK" push -q origin main
  run "$RELEASE" v9.9.9
  assert_success
  assert_output_contains "finishing v9.9.9"
  assert_file_contains "$WORK/Formula/ada.rb" "sha256 \"$(expected_sha v9.9.9)\""
  run git -C "$ORIGIN" log -1 --format=%s main
  assert_equal "$output" "Homebrew: point formula at v9.9.9"
}

@test "a formula edit racing the release stops with a re-run hint" {
  export STUB_CURL_ADVANCE="$ORIGIN" STUB_CURL_ADVANCE_FORMULA=1
  run "$RELEASE" v9.9.9
  assert_failure
  assert_output_contains "conflicts with origin/main"
  assert_output_contains "re-run ./release.sh v9.9.9"
  run git -C "$WORK" status --porcelain
  assert_equal "$output" ""
  # main is back on origin/main, so the hinted re-run really does finish it
  assert_equal "$(git -C "$WORK" rev-parse HEAD)" "$(git -C "$ORIGIN" rev-parse main)"
  run "$RELEASE" v9.9.9
  assert_success
  assert_output_contains "finishing v9.9.9"
  run git -C "$ORIGIN" log -1 --format=%s main
  assert_equal "$output" "Homebrew: point formula at v9.9.9"
}

# --- no downgrades; which PRs a release covers -------------------------------

@test "re-running an older published version refuses to downgrade the formula" {
  finished_release v0.5
  git -C "$WORK" commit -q --allow-empty -m "more work"
  finished_release v0.6
  git -C "$WORK" push -q origin main --tags
  run "$RELEASE" v0.5
  assert_failure
  assert_output_contains "older than the formula's v0.6; refusing to downgrade"
  assert_file_contains "$WORK/Formula/ada.rb" "refs/tags/v0.6.tar.gz"
}

@test "--next never offers to finish a tag older than the formula's version" {
  finished_release v0.6
  git -C "$WORK" tag -a v0.5 -m v0.5 HEAD~1
  run "$RELEASE" --next minor
  assert_success
  assert_equal "$output" "v0.7"
}

@test "--next counts from the formula's version when it is ahead of the tags" {
  sed -i '' 's|^  url ".*"|  url "https://github.com/janacm/ada/archive/refs/tags/v2.3.tar.gz"|' "$WORK/Formula/ada.rb"
  git -C "$WORK" commit -q -am "formula at v2.3"
  git -C "$WORK" tag -a v0.4 -m v0.4
  run "$RELEASE" --next minor
  assert_equal "$output" "v2.4"
}

@test "--prs-since-release lists merge and squash PRs after the formula's version" {
  git -C "$WORK" commit -q --allow-empty -m "Old work (#5)"
  finished_release v0.4
  git -C "$WORK" commit -q --allow-empty -m "Merge pull request #12 from janacm/feature"
  git -C "$WORK" commit -q --allow-empty -m "A squashed change (#13)"
  git -C "$WORK" commit -q --allow-empty -m "Direct push, no PR"
  run "$RELEASE" --prs-since-release
  assert_success
  assert_equal "$(echo $output)" "12 13"
}

@test "--prs-since-release with no release tag looks at all of history" {
  git -C "$WORK" commit -q --allow-empty -m "Merge pull request #3 from janacm/x"
  run "$RELEASE" --prs-since-release
  assert_equal "$output" "3"
}

@test "--next ignores a newer tag on another branch" {
  finished_release v0.4
  git -C "$WORK" switch -q -c side
  git -C "$WORK" commit -q --allow-empty -m "side work"
  git -C "$WORK" tag -a v0.9 -m v0.9
  git -C "$WORK" push -q origin v0.9
  git -C "$WORK" switch -q main
  run "$RELEASE" --next minor
  assert_success
  assert_equal "$output" "v0.5"
}

@test "--next does not offer to finish a local-only tag" {
  finished_release v0.4
  git -C "$WORK" commit -q --allow-empty -m "more work"
  git -C "$WORK" tag -a v0.7 -m v0.7    # never pushed
  run "$RELEASE" --next minor
  assert_success
  refute_output_contains "finishing"
  assert_equal "$output" "v0.5"
}

# --- --auto: the release workflow's whole job ---------------------------------

# A finished v0.4 on origin, then a merged PR on top: the state the workflow
# sees after a labelled merge.
released_v04_then_pr() {
  finished_release v0.4
  git -C "$WORK" commit -q --allow-empty -m "Merge pull request #${1:-20} from janacm/feature"
  git -C "$WORK" push -q origin main --tags
}

@test "--auto minor releases the tested main as the next minor" {
  released_v04_then_pr
  tested=$(git -C "$WORK" rev-parse HEAD)
  run "$RELEASE" --auto minor
  assert_success
  assert_equal "$(git -C "$ORIGIN" rev-parse 'v0.5^{commit}')" "$tested"
  assert_file_contains "$WORK/Formula/ada.rb" "refs/tags/v0.5.tar.gz"
}

@test "--auto goes major when an earlier PR since the release asked for it" {
  released_v04_then_pr 20
  git -C "$WORK" commit -q --allow-empty -m "A later minor change (#21)"
  git -C "$WORK" push -q origin main
  export STUB_GH_MAJOR="20"
  run "$RELEASE" --auto minor
  assert_success
  assert_output_contains "#20 asked for a major release"
  run git -C "$ORIGIN" tag -l v1.0
  assert_equal "$output" "v1.0"
}

@test "--auto finishes a stranded tag, then releases the tested main too" {
  finished_release v0.4
  git -C "$WORK" commit -q --allow-empty -m "Merge pull request #19 from janacm/earlier"
  git -C "$WORK" tag -a v0.5 -m v0.5          # an earlier run died after this push
  git -C "$WORK" commit -q --allow-empty -m "Merge pull request #20 from janacm/feature"
  git -C "$WORK" push -q origin main --tags
  stranded=$(git -C "$WORK" rev-parse 'v0.5^{commit}')
  tested=$(git -C "$WORK" rev-parse HEAD)
  run "$RELEASE" --auto minor
  assert_success
  assert_output_contains "finishing v0.5"
  assert_output_contains "now releasing the tested main"
  assert_equal "$(git -C "$ORIGIN" rev-parse 'v0.5^{commit}')" "$stranded"
  # v0.6 names the commit the suite ran on, not the v0.5 formula bump
  assert_equal "$(git -C "$ORIGIN" rev-parse 'v0.6^{commit}')" "$tested"
  run git -C "$ORIGIN" log --format=%s -3 main
  assert_equal "${lines[0]}" "Homebrew: point formula at v0.6"
  assert_equal "${lines[1]}" "Homebrew: point formula at v0.5"
  assert_equal "${lines[2]}" "Merge pull request #20 from janacm/feature"
}

@test "--auto leaves untested commits from a concurrent merge for the next release" {
  finished_release v0.4
  git -C "$WORK" tag -a v0.5 -m v0.5
  git -C "$WORK" commit -q --allow-empty -m "Merge pull request #20 from janacm/feature"
  git -C "$WORK" push -q origin main --tags
  export STUB_CURL_ADVANCE="$ORIGIN"
  run "$RELEASE" --auto minor
  assert_success
  assert_output_contains "finishing v0.5"
  assert_output_contains "newer commits ship with the next labelled merge"
  run git -C "$ORIGIN" tag -l v0.6
  assert_equal "$output" ""
}

@test "--auto rejects anything but minor or major" {
  run "$RELEASE" --auto patch
  assert_failure
  assert_output_contains "usage: release.sh --auto minor|major"
}

@test "--auto stops rather than guess when a PR's labels can't be read" {
  released_v04_then_pr 20
  cat > "$BATS_TEST_TMPDIR/bin/gh" <<'SH'
#!/bin/bash
echo "HTTP 502" >&2; exit 1
SH
  run "$RELEASE" --auto minor
  assert_failure
  assert_output_contains "could not read the labels of #20; not releasing"
  run git -C "$ORIGIN" tag -l v0.5
  assert_equal "$output" ""
}
