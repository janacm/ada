#!/bin/bash
# =============================================================
# test/coverage/run.sh — every test suite, with line coverage
# -------------------------------------------------------------
# Invoked as `./run-tests.sh --coverage [bats args]`. Runs the same
# hermetic suites, with every child process instrumented:
#
#   bash    BASH_ENV=bash_env.sh (a DEBUG trap; see that file for
#           why kcov and bashcov can't do this on macOS bash 3.2)
#   zsh     ZDOTDIR=zdotdir, whose .zshenv installs TRAPDEBUG
#   python  coverage.py, started in every python3 by sitecustomize;
#           patch=_exit keeps the snooze daemon's forked parents, which
#           leave through os._exit, from dropping their data. Python
#           embedded in the shell scripts goes through bin/python3, which
#           gives each program a file coverage.py can measure
#   node    NODE_V8_COVERAGE, converted to line coverage by c8
#   swift   one -profile-generate build of the package; `swift test`
#           and the bats CLI tests (test/ada-alert.bats) both run it,
#           and llvm-cov merges their profiles
#   page    alert.html's inline script, via Playwright's V8 coverage
#           (needs `npm install && npx playwright install chromium`)
#
# Results land in .cov/ (gitignored). coverage.py lives in a private
# venv at .cov/venv and c8 comes from npx, so neither is a dependency
# of ada itself. Swift and the page are skipped, with a note, when
# their toolchain is missing; ADA_COV_SWIFT=0 / ADA_COV_PAGE=0 skip
# them on purpose. Exits non-zero if any suite failed or any collected
# data could not be reported; the report is printed either way.
# ADA_COV_MISSING=1 lists uncovered lines per file.
# =============================================================
set -u

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
out="$root/.cov"
venv="$out/venv"
status=0

# A step that collected data but could not turn it into a report.
measure_failed() {
  echo "coverage: $1; that language is missing from the total below" >&2
  status=1
}

rm -rf "$out/shell" "$out/py" "$out/node" "$out/js" "$out/python.json" "$out/embedded" \
       "$out/page" "$out/swift-prof" "$out/swift.lcov" "$out/swift.profdata"
mkdir -p "$out/shell" "$out/py" "$out/node" "$out/embedded"

# The venv must come from the python3 the scripts will actually run, or the
# coverage C extension won't import into it.
if ! "$venv/bin/python" -c 'import coverage' 2>/dev/null; then
  python3 -m venv "$venv" && "$venv/bin/pip" -q install coverage \
    || { echo "coverage: could not install coverage.py into $venv" >&2; exit 1; }
fi
site=$("$venv/bin/python" -c 'import coverage, os; print(os.path.dirname(os.path.dirname(coverage.__file__)))')

cat > "$out/coveragerc" <<EOF
[run]
parallel = true
data_file = $out/py/.coverage
source =
    $root/lib
    $out/embedded
sigterm = true
patch = _exit
EOF

# --- swift: build instrumented, before any shell instrumentation is live ------
swift_bin=""
swift_flags=(-Xswiftc -profile-generate -Xswiftc -profile-coverage-mapping)
if [[ "${ADA_COV_SWIFT:-1}" != 0 ]] && command -v swift >/dev/null 2>&1; then
  # The Command Line Tools ship Swift Testing's macro plugin, but SwiftPM's
  # default build system does not put it on the plugin path (Swift 6.4), so
  # every @Test fails to expand. Xcode's toolchain has the same directory, so
  # naming it is harmless there.
  testing_plugins="$(dirname "$(xcrun --find swift 2>/dev/null || command -v swift)")/../lib/swift/host/plugins/testing"
  [[ -d "$testing_plugins" ]] && swift_flags+=(-Xswiftc -plugin-path -Xswiftc "$testing_plugins")
  echo "coverage: building an instrumented Swift package..."
  if (cd "$root" && swift build --build-path "$out/swift-build" --build-tests "${swift_flags[@]}") \
       > "$out/swift-build.log" 2>&1; then
    swift_bin=$(cd "$root" && swift build --build-path "$out/swift-build" --show-bin-path)
    mkdir -p "$out/swift-prof"
    export ADA_ALERT_UNDER_TEST="$swift_bin/ada-alert" ADA_MENUBAR_UNDER_TEST="$swift_bin/ada-menubar"
    export LLVM_PROFILE_FILE="$out/swift-prof/bats-%p.profraw"
  else
    echo "coverage: instrumented swift build failed (see $out/swift-build.log); Swift not measured" >&2
    status=1
  fi
fi

# --- bats, with shell / python / node instrumentation ------------------------
export ADA_COV_ROOT="$root" ADA_COV_DIR="$out/shell"
export BASH_ENV="$root/test/coverage/bash_env.sh"
export ZDOTDIR="$root/test/coverage/zdotdir"
export COVERAGE_PROCESS_START="$out/coveragerc"
export PYTHONPATH="$root/test/coverage/py:$site${PYTHONPATH:+:$PYTHONPATH}"
export NODE_V8_COVERAGE="$out/node"
export ADA_COV_REAL_PYTHON="$(command -v python3)" ADA_COV_EMBED_DIR="$out/embedded"
export PATH="$root/test/coverage/bin:$PATH"

chmod +x "$root"/test/stubs/* 2>/dev/null || true
if [[ $# -gt 0 ]]; then
  bats "$@" || status=1
else
  bats "$root/test/" || status=1
fi

unset BASH_ENV ZDOTDIR COVERAGE_PROCESS_START PYTHONPATH NODE_V8_COVERAGE ADA_COV_DIR
PATH=${PATH#"$root/test/coverage/bin:"}

# --- swift unit tests, against the same instrumented build -------------------
if [[ -n "$swift_bin" ]]; then
  if ! (cd "$root" && LLVM_PROFILE_FILE="$out/swift-prof/test-%p.profraw" \
          swift test --build-path "$out/swift-build" --skip-build "${swift_flags[@]}") \
       > "$out/swift-test.log" 2>&1; then
    echo "coverage: swift test FAILED (see $out/swift-test.log)" >&2
    status=1
  fi
  unset LLVM_PROFILE_FILE
  test_bin=$(find "$swift_bin" -path '*.xctest/Contents/MacOS/*' -type f -perm -u+x | head -1)
  if ! ls "$out"/swift-prof/*.profraw >/dev/null 2>&1; then
    measure_failed "no Swift profiles were written"
  elif ! xcrun llvm-profdata merge -sparse "$out"/swift-prof/*.profraw -o "$out/swift.profdata"; then
    measure_failed "llvm-profdata merge failed"
  elif ! xcrun llvm-cov export -format=lcov -instr-profile "$out/swift.profdata" \
         "$swift_bin/ada-alert" -object "$swift_bin/ada-menubar" ${test_bin:+-object "$test_bin"} \
         -ignore-filename-regex='(Tests/|/\.cov/|/\.build/)' > "$out/swift.lcov"; then
    rm -f "$out/swift.lcov"
    measure_failed "llvm-cov export failed"
  fi
fi

# --- alert.html, through the Playwright specs ------------------------------------
if [[ "${ADA_COV_PAGE:-1}" != 0 ]]; then
  if [[ -d "$root/node_modules/@playwright/test" ]]; then
    if ! (cd "$root" && ADA_COV_JS_DIR="$out/page" npx playwright test --reporter=dot) \
         > "$out/playwright.log" 2>&1; then
      echo "coverage: Playwright specs FAILED (see $out/playwright.log)" >&2
      status=1
    fi
  else
    echo "coverage: Playwright not installed (npm install && npx playwright install chromium); alert.html not measured" >&2
  fi
fi

# --- reports ------------------------------------------------------------------
# A language whose data was collected but could not be converted must fail the
# run: report.py would otherwise leave it out of the denominator and print a
# higher total with no sign anything was missing. A subset run (a single .bats
# file) that simply never started python or node has no data to convert.
if ls "$out"/py/.coverage.* >/dev/null 2>&1; then
  ( cd "$out/py" && "$venv/bin/python" -m coverage combine --rcfile="$out/coveragerc" -q . \
      && "$venv/bin/python" -m coverage json --rcfile="$out/coveragerc" -q -o "$out/python.json" ) \
    || measure_failed "coverage.py could not combine or report its data"
fi

if [[ -n "$(ls -A "$out/node" 2>/dev/null)" ]]; then
  ( cd "$root" && npx --yes c8@10 report --temp-directory "$out/node" \
      --reports-dir "$out/js" --reporter json --include 'lib/**' >/dev/null ) \
    || measure_failed "c8 report failed"
fi

echo
python3 "$root/test/coverage/report.py" "$root" "$out" ${ADA_COV_MISSING:+--missing}
exit $status
