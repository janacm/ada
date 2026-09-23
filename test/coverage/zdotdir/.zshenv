# zsh reads $ZDOTDIR/.zshenv on every start, `zsh -c` included, so pointing
# ZDOTDIR here during `./run-tests.sh --coverage` records which lines of ada.sh
# the suite runs. funcfiletrace[1] is "file:line" of the command about to run,
# and TRAPDEBUG is inherited by functions, unlike a plain `trap ... DEBUG`.
# As in bash_env.sh, paths are kept as run and report.py resolves symlinks.
[[ -n ${ADA_COV_DIR:-} ]] || return 0
TRAPDEBUG() {
  [[ ${funcfiletrace[1]-} == /* ]] &&
    print -r -- "${funcfiletrace[1]}" >> "$ADA_COV_DIR/zsh.$$"
  return 0
}
