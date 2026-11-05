#!/bin/bash
# =============================================================
# ada-sources — which agents, harnesses and projects may raise an alert
# -------------------------------------------------------------
# Every integration names where its alert came from in ADA_SOURCE:
#   terminal          the zsh hook (ada.sh)
#   claude/desktop    Claude Code in the Claude desktop app
#   claude/cli        Claude Code started as `claude` in a terminal
#   claude/ide        Claude Code in an IDE extension
#   claude/headless   `claude -p` and Agent SDK runs
#   claude            Claude Code started any other way
#   codex             Codex (it shares the Claude Code hook)
#   opencode          the opencode plugin
#   paseo/<provider>  a Paseo agent, by provider: paseo/claude, paseo/codex, ...
# and lib/ada-show-alert.sh drops an alert whose source or project is switched
# off here, before it is recorded or shown. An alert without ADA_SOURCE (a test
# alert, or one from an older integration) is never dropped, and neither is one
# that passes ADA_IGNORE_PAUSE=1, the flag every test alert sets.
#
# The rules live in one file, ~/.config/ada/sources (ADA_SOURCES_FILE), outside
# $TMPDIR because they must survive a restart, and outside ~/Documents so a
# LaunchAgent may read them. One rule per line, `#` starts a comment:
#   off source paseo          no Paseo agent alerts...
#   on source paseo/claude    ...except from Paseo's claude agents
#   off repo sandbox  nothing from this project
#   off repo *                only the projects turned on by name:
#   on repo ada
# A source rule covers the sources under it, and the most specific rule wins:
# paseo/claude, then paseo, then *. The built-in defaults are rules too, which
# a rule for the same name in the file replaces. There is one:
#   off source claude/headless
# A repo rule names a project the way the alert's repo badge does: the folder
# name of the git top level, or a Paseo agent's folder. `repo *` covers every
# project, and alerts from outside any repo as well. An alert shows only when
# both its source and its project are on.
#
# Executed, it is the CLI (Homebrew: ada-sources):
#   ada-sources.sh [list]               every source and project, on or off, and why
#   ada-sources.sh on|off <source>...   turn sources on or off; this also drops
#                                       the rules for the sources under each one
#   ada-sources.sh on|off repo <name>... turn projects on or off (`*` = all)
#   ada-sources.sh only repo <name>...  alert only for these projects
#   ada-sources.sh unset <source>...    back to the default
#   ada-sources.sh unset repo <name>...
#   ada-sources.sh reset                forget every rule in the file
#   ada-sources.sh check <source> [repo] exit 0 when such an alert would show
#                                       (no repo: the source switch alone)
#   ada-sources.sh path                 print the rules file
#   ada-sources.sh init                 create the rules file, then print it
#
# Sourced by lib/ada-show-alert.sh for __ada_sources_load and
# __ada_source_allowed, which cost no subshells: they run on every alert.
# =============================================================
set -u

# The rules file. HOME, not XDG_CONFIG_HOME: a LaunchAgent (the Paseo watcher,
# the menu bar) does not inherit a terminal's XDG_CONFIG_HOME, and every
# process that reads the rules has to agree on where they are.
__ada_sources_path() {
  __ada_src_file=${ADA_SOURCES_FILE:-${HOME:-~}/.config/ada/sources}
}

# The sources the integrations send, with what the CLI calls them. paseo/* is
# open-ended (one per provider), so `list` adds the ones it has seen.
__ada_src_known=(terminal claude claude/desktop claude/cli claude/ide claude/headless codex opencode paseo)
__ada_src_titles=("Terminal commands" "Claude Code, any surface" "Claude desktop app"
                  "Claude Code in a terminal" "Claude Code in an IDE" "claude -p and Agent SDK runs"
                  "Codex" "opencode" "Paseo agents")

# __ada_source_default <key>: the built-in rule for exactly this key, in
# __ada_src_def. One today: headless runs come from scripts, and a `claude -p`
# you run by hand already gets the terminal alert.
__ada_source_default() {
  case "$1" in
    claude/headless) __ada_src_def=off; return 0 ;;
  esac
  return 1
}

# A source key: `*`, or names of letters, digits, `.`, `_` and `-` joined by `/`.
__ada_source_key_ok() {
  local re='^[A-Za-z0-9][A-Za-z0-9._-]*(/[A-Za-z0-9][A-Za-z0-9._-]*)*$'
  [[ "$1" == "*" ]] && return 0
  (( ${#1} <= 100 )) && [[ "$1" =~ $re ]]
}

# __ada_sources_parse <line>: one rule into __ada_p_state, __ada_p_kind and
# __ada_p_name; false for a comment, a blank line or anything malformed. A
# project name keeps its inner spaces (it is the rest of the line), and the
# trimming takes a CRLF file's \r with it.
__ada_sources_parse() {
  local line=$1 rest
  line=${line#"${line%%[![:space:]]*}"}
  [[ -z "$line" || "$line" == \#* ]] && return 1
  __ada_p_state=${line%%[[:space:]]*}
  rest=${line#"$__ada_p_state"}
  rest=${rest#"${rest%%[![:space:]]*}"}
  __ada_p_kind=${rest%%[[:space:]]*}
  rest=${rest#"$__ada_p_kind"}
  rest=${rest#"${rest%%[![:space:]]*}"}
  __ada_p_name=${rest%"${rest##*[![:space:]]}"}
  [[ "$__ada_p_state" == on || "$__ada_p_state" == off ]] || return 1
  case "$__ada_p_kind" in
    source) __ada_source_key_ok "$__ada_p_name" ;;
    repo) [[ -n "$__ada_p_name" && "$__ada_p_name" != *$'\t'* ]] ;;
    *) return 1 ;;
  esac
}

# Read the rules, in file order, into three parallel arrays (bash 3.2 has no
# associative ones). A missing or unreadable file is no rules, so the defaults.
# __ada_src_has_repo says whether any rule is about projects, because only then
# does an alert's project have to be known before it is decided.
__ada_sources_load() {
  __ada_src_state=(); __ada_src_kind=(); __ada_src_name=()
  __ada_src_has_repo=0
  __ada_sources_path
  [[ -f "$__ada_src_file" && -r "$__ada_src_file" ]] || return 0
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    __ada_sources_parse "$line" || continue
    __ada_src_state+=("$__ada_p_state")
    __ada_src_kind+=("$__ada_p_kind")
    __ada_src_name+=("$__ada_p_name")
    [[ "$__ada_p_kind" == repo ]] && __ada_src_has_repo=1
  done < "$__ada_src_file"
  return 0
}

# __ada_src_rule <kind> <name>: the last rule in the file for exactly this
# name, in __ada_src_found ("" when none). A later line replaces an earlier one.
__ada_src_rule() {
  local i
  __ada_src_found=""
  for (( i = 0; i < ${#__ada_src_kind[@]}; i++ )); do
    [[ "${__ada_src_kind[$i]}" == "$1" && "${__ada_src_name[$i]}" == "$2" ]] \
      && __ada_src_found=${__ada_src_state[$i]}
  done
  return 0
}

# __ada_source_lookup <source>: whether alerts from it show, in __ada_src_on
# (on|off), and what decided it in __ada_src_why: "rule <key>", "default <key>",
# or "" when nothing did. Walks from the source up to *, taking the file's rule
# before the built-in one at each step.
__ada_source_lookup() {
  local key=$1
  while :; do
    __ada_src_rule source "$key"
    if [[ -n "$__ada_src_found" ]]; then
      __ada_src_on=$__ada_src_found; __ada_src_why="rule $key"; return 0
    fi
    if __ada_source_default "$key"; then
      __ada_src_on=$__ada_src_def; __ada_src_why="default $key"; return 0
    fi
    [[ "$key" == "*" ]] && break
    if [[ "$key" == */* ]]; then key=${key%/*}; else key="*"; fi
  done
  __ada_src_on=on; __ada_src_why=""
}

# __ada_repo_lookup <project>: the same for a project, "" meaning no repo.
__ada_repo_lookup() {
  local key
  for key in "$1" "*"; do
    [[ -n "$key" ]] || continue
    __ada_src_rule repo "$key"
    if [[ -n "$__ada_src_found" ]]; then
      __ada_src_on=$__ada_src_found; __ada_src_why="rule $key"; return 0
    fi
  done
  __ada_src_on=on; __ada_src_why=""
}

# __ada_source_allowed <source> [project]: true when such an alert may show.
# Call __ada_sources_load first.
__ada_source_allowed() {
  __ada_source_lookup "$1"
  [[ "$__ada_src_on" == on ]] || return 1
  [[ "$__ada_src_has_repo" == 1 ]] || return 0
  __ada_repo_lookup "${2:-}"
  [[ "$__ada_src_on" == on ]]
}

# --- the CLI: every write to the rules file goes through here -----------------

__ada_sources_die() { printf 'ada-sources: %s\n' "$*" >&2; exit 1; }

# The file a write lands in. A dotfiles manager may have made the rules file a
# symlink; replacing it by rename would leave a detached copy, so a write goes
# to the file the link points at.
__ada_sources_target() {
  local file=$1 link n=0
  while [[ -L "$file" ]] && (( n++ < 16 )); do
    link=$(readlink "$file") || break
    [[ "$link" == /* ]] || link="$(dirname "$file")/$link"
    file=$link
  done
  printf '%s' "$file"
}

__ada_sources_header() {
  cat <<'HEADER'
# ada alert switches: which agents, harnesses and projects may raise an alert.
# One rule per line:  on|off source <source>   or   on|off repo <project>
# Sources: terminal, claude, claude/desktop, claude/cli, claude/ide,
#   claude/headless (off unless a rule here turns it on), codex, opencode,
#   paseo, paseo/<provider>. A rule covers the sources under it, and the most
#   specific rule wins: paseo/claude, then paseo, then *.
# Projects: a repo's folder name, or * for every project (and for alerts from
#   outside a repo). An alert shows only when its source and project are on.
# Change it here, with ada-sources (lib/ada-sources.sh), or from the menu bar.
HEADER
}

# __ada_sources_save <content>: replace the rules file, atomically: a temp file
# beside the target, then a rename, so a launcher reading it mid-write sees the
# old rules or the new ones, never half.
__ada_sources_save() {
  local content=$1 target dir tmp
  __ada_sources_path
  target=$(__ada_sources_target "$__ada_src_file")
  [[ -e "$target" && ! -f "$target" ]] && __ada_sources_die "$target is not a file; left alone"
  dir=$(dirname "$target")
  mkdir -p "$dir" 2>/dev/null || __ada_sources_die "cannot create $dir"
  tmp=$(mktemp "$target.XXXXXX" 2>/dev/null) || __ada_sources_die "cannot write in $dir"
  if ! { printf '%s' "$content" > "$tmp" && chmod 644 "$tmp" && mv -f "$tmp" "$target"; }; then
    rm -f "$tmp"
    __ada_sources_die "could not write $target"
  fi
}

# The file's current text, or a fresh header when there is no file.
__ada_sources_text() {
  __ada_sources_path
  if [[ -f "$__ada_src_file" ]]; then
    __ada_src_text=$(cat "$__ada_src_file"; printf x)
    __ada_src_text=${__ada_src_text%x}
  else
    __ada_src_text=$(__ada_sources_header; printf x)
    __ada_src_text=${__ada_src_text%x}
  fi
}

# __ada_sources_edit <kind> <name> <state|""> [match-all-of-kind]: drop the
# rules for <name> (for a source, the ones under it as well), then add
# "<state> <kind> <name>" unless state is empty. Comments, other rules and
# lines it can't parse are kept as they are.
__ada_sources_edit() {
  local kind=$1 name=$2 state=$3 all=${4:-0} out="" line drop
  __ada_sources_text
  while IFS= read -r line || [[ -n "$line" ]]; do
    drop=0
    if __ada_sources_parse "$line" && [[ "$__ada_p_kind" == "$kind" ]]; then
      if [[ "$all" == 1 || "$__ada_p_name" == "$name" ]]; then
        drop=1
      elif [[ "$kind" == source && "$name" != "*" && "$__ada_p_name" == "$name"/* ]]; then
        drop=1
      fi
    fi
    [[ "$drop" == 1 ]] || out+="$line"$'\n'
  done <<< "${__ada_src_text%$'\n'}"
  [[ -n "$state" ]] && out+="$state $kind $name"$'\n'
  __ada_src_text=$out
}

# The sources worth listing beyond the known ones: every paseo/<provider> (or
# other source) seen in the alert history's 15th column or named by a rule.
__ada_sources_extra() {
  local history i key
  history=${ADA_HISTORY_FILE:-${TMPDIR:-/tmp}/ada-history.tsv}
  {
    if [[ -f "$history" && ! -L "$history" ]]; then
      awk -F '\t' '$1 == "1" && NF >= 15 && $15 != "" { print $15 }' "$history" 2>/dev/null
    fi
    for (( i = 0; i < ${#__ada_src_kind[@]}; i++ )); do
      [[ "${__ada_src_kind[$i]}" == source && "${__ada_src_name[$i]}" != "*" ]] \
        && printf '%s\n' "${__ada_src_name[$i]}"
    done
  } | sort -u | while IFS= read -r key; do
    __ada_source_known "$key" && continue
    __ada_source_key_ok "$key" && printf '%s\n' "$key"
  done
}

__ada_source_known() {
  local k
  for k in "${__ada_src_known[@]}"; do [[ "$k" == "$1" ]] && return 0; done
  return 1
}

__ada_source_title() {
  local i
  for (( i = 0; i < ${#__ada_src_known[@]}; i++ )); do
    [[ "${__ada_src_known[$i]}" == "$1" ]] && { printf '%s' "${__ada_src_titles[$i]}"; return 0; }
  done
  case "$1" in
    paseo/*) printf 'Paseo %s agents' "${1#paseo/}" ;;
    claude/*) printf 'Claude Code (%s)' "${1#claude/}" ;;
    *) printf '%s' "$1" ;;
  esac
}

# "(set)", "(default)", "(from paseo)" or nothing, for one row of `list`.
__ada_sources_why() {
  local key=$1
  case "$__ada_src_why" in
    "rule $key") printf ' (set)' ;;
    "default $key") printf ' (default)' ;;
    "rule *") printf ' (from source *)' ;;
    rule\ *) printf ' (from %s)' "${__ada_src_why#rule }" ;;
    default\ *) printf ' (default for %s)' "${__ada_src_why#default }" ;;
  esac
}

__ada_sources_list() {
  local key i seen=" " name
  __ada_sources_load
  printf 'Rules: %s%s\n\n' "$__ada_src_file" "$([[ -f "$__ada_src_file" ]] || printf ' (none yet)')"
  printf 'Sources\n'
  { for key in "${__ada_src_known[@]}"; do printf '%s\n' "$key"; done; __ada_sources_extra; } \
    | while IFS= read -r key; do
        __ada_source_lookup "$key"
        printf '  %-4s %-20s %s%s\n' "$__ada_src_on" "$key" "$(__ada_source_title "$key")" "$(__ada_sources_why "$key")"
      done
  printf '\nProjects\n'
  __ada_src_rule repo "*"
  if [[ "$__ada_src_found" == off ]]; then
    printf '  only the projects turned on below\n'
  else
    printf '  every project, except any turned off below\n'
  fi
  for (( i = 0; i < ${#__ada_src_kind[@]}; i++ )); do
    name=${__ada_src_name[$i]}
    [[ "${__ada_src_kind[$i]}" == repo && "$name" != "*" && "$seen" != *" $name "* ]] || continue
    seen+="$name "
    __ada_repo_lookup "$name"
    printf '  %-4s %s\n' "$__ada_src_on" "$name"
  done
  return 0
}

__ada_sources_usage() {
  sed -n '/^# Executed, it is the CLI/,/^# Sourced by/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
}

__ada_sources_cli() {
  local action=${1:-list} kind name state
  [[ $# -gt 0 ]] && shift
  case "$action" in
    list) __ada_sources_list ;;
    path) __ada_sources_path; printf '%s\n' "$__ada_src_file" ;;
    init)
      __ada_sources_path
      [[ -f "$__ada_src_file" ]] || __ada_sources_save "$(__ada_sources_header)"$'\n'
      printf '%s\n' "$__ada_src_file"
      ;;
    on|off|unset)
      state=$action; [[ "$state" == unset ]] && state=""
      kind=source
      if [[ "${1:-}" == repo ]]; then kind=repo; shift; fi
      [[ $# -gt 0 ]] || __ada_sources_die "$action: name a $kind (ada-sources list shows them)"
      for name in "$@"; do
        if [[ "$kind" == source ]]; then
          __ada_source_key_ok "$name" || __ada_sources_die "not a source: '$name'"
          if ! __ada_source_known "$name" && [[ "$name" != "*" && "$name" != paseo/* ]]; then
            printf 'ada-sources: note: no integration sends "%s" yet; the rule is kept anyway\n' "$name" >&2
          fi
        else
          [[ -n "$name" && "$name" != *$'\t'* && "$name" != *$'\n'* ]] || __ada_sources_die "not a project name: '$name'"
        fi
        __ada_sources_edit "$kind" "$name" "$state"
        __ada_sources_save "$__ada_src_text"
      done
      for name in "$@"; do
        __ada_sources_load
        if [[ "$kind" == source ]]; then __ada_source_lookup "$name"; else __ada_repo_lookup "$name"; fi
        printf '%s %s: %s\n' "$kind" "$name" "$__ada_src_on"
      done
      ;;
    only)
      [[ "${1:-}" == repo ]] || __ada_sources_die "only works for projects: ada-sources only repo <name>..."
      shift
      [[ $# -gt 0 ]] || __ada_sources_die "only repo: name at least one project"
      __ada_sources_edit repo "*" "" 1
      __ada_src_text+="off repo *"$'\n'
      for name in "$@"; do
        [[ -n "$name" && "$name" != "*" && "$name" != *$'\t'* && "$name" != *$'\n'* ]] \
          || __ada_sources_die "not a project name: '$name'"
        __ada_src_text+="on repo $name"$'\n'
      done
      __ada_sources_save "$__ada_src_text"
      printf 'alerts only for: %s\n' "$*"
      ;;
    reset)
      __ada_sources_path
      if [[ -f "$__ada_src_file" ]]; then
        __ada_sources_edit source "*" "" 1
        __ada_sources_save "$__ada_src_text"
        __ada_sources_edit repo "*" "" 1
        __ada_sources_save "$__ada_src_text"
      fi
      echo "every source and project back to its default"
      ;;
    check)
      [[ $# -ge 1 ]] || __ada_sources_die "check: name a source"
      __ada_sources_load
      # No project argument judges the source alone; an empty one is an alert
      # from outside any repo, which `repo *` decides.
      [[ $# -ge 2 ]] || __ada_src_has_repo=0
      if __ada_source_allowed "$1" "${2:-}"; then echo on; return 0; fi
      echo off
      return 1
      ;;
    -h|--help|help) __ada_sources_usage ;;
    *)
      printf 'ada-sources: unknown command: %s\n' "$action" >&2
      __ada_sources_usage >&2
      return 2
      ;;
  esac
}

# Executed directly -> CLI. Sourced -> just define the functions above.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  __ada_sources_cli "$@"
fi
