# BASH_ENV for `./run-tests.sh --coverage`.
#
# Every non-interactive bash reads $BASH_ENV before it runs, so each script the
# suite spawns (hooks, launcher, installer, watcher front door) records the lines
# it executes, however deep in the process tree it starts. The usual tools can't
# do this here: macOS /bin/bash is 3.2, which has no BASH_XTRACEFD for kcov's or
# bashcov's xtrace mode, and kcov's DEBUG mode unsets BASH_ENV, so it only sees
# the top-level script and never the children bats spawns.
#
# functrace makes the trap follow into functions, command substitutions and
# subshells. A `case` always returns 0, so the trap can't trip a script's own
# `set -e`. Paths are recorded as run, not resolved: a test may run a repo
# script through a symlink in a fixture dir (release.bats does), and report.py
# resolves every path with realpath before matching it to a repo file. A
# relative path gets $PWD in front so it still resolves there.
#
# Keep the trap on ONE line. bash 3.2 adds the offset of the running line
# within a multi-line trap string to $LINENO, so a trap body split over lines
# records every hit two or three lines late.
[ -n "${ADA_COV_DIR:-}" ] || return 0
set -o functrace
trap 'case ${BASH_SOURCE[0]-} in "" | */bats-core/*) ;; /*) printf "%s:%s\n" "${BASH_SOURCE[0]}" "$LINENO" >> "$ADA_COV_DIR/bash.$$" ;; *) printf "%s/%s:%s\n" "$PWD" "${BASH_SOURCE[0]}" "$LINENO" >> "$ADA_COV_DIR/bash.$$" ;; esac' DEBUG
