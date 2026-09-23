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
printf 'fake tarball for %s' "${!#}"
SH
  chmod +x "$BATS_TEST_TMPDIR/bin/curl"
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
