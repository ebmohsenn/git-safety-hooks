# shellcheck shell=bash
# config.sh — settings lookup shared by every hook. Source it; do not execute it.
#
# A setting such as `secretScan.envFile` is looked up, first hit wins, in:
#   1. git config `safety.<key>`            (repo .git/config, ~/.gitconfig, system)
#   2. the committed repo file              ($GIT_SAFETY_CONFIG, default <repo>/.git-safety.conf)
#   3. the default given by the caller
# The repo file uses git-config syntax and is READ with `git config -f`, never sourced, so a
# settings file cannot execute code.
#
# Per-run overrides are plain environment variables, documented next to each check.

SAFETY_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

_safety_conf_file() {
  local f="${GIT_SAFETY_CONFIG:-$SAFETY_ROOT/.git-safety.conf}"
  case "$f" in /*) ;; *) f="$SAFETY_ROOT/$f" ;; esac
  printf '%s\n' "$f"
}

# cfg_get <key> [default] — single value (the last one wins, as in git).
cfg_get() {
  local key="$1" def="${2-}" v f
  if v="$(git config --get "safety.$key" 2>/dev/null)"; then printf '%s\n' "$v"; return 0; fi
  f="$(_safety_conf_file)"
  if [ -f "$f" ] && v="$(git config -f "$f" --get "$key" 2>/dev/null)"; then printf '%s\n' "$v"; return 0; fi
  printf '%s\n' "$def"
}

# cfg_all <key> — every value, one per line (git config first, then the repo file).
cfg_all() {
  local key="$1" f
  git config --get-all "safety.$key" 2>/dev/null || true
  f="$(_safety_conf_file)"
  if [ -f "$f" ]; then git config -f "$f" --get-all "$key" 2>/dev/null || true; fi
}

# cfg_bool <key> <default true|false> — prints true or false.
cfg_bool() {
  local key="$1" def="$2" v f
  if v="$(git config --bool --get "safety.$key" 2>/dev/null)"; then printf '%s\n' "$v"; return 0; fi
  f="$(_safety_conf_file)"
  if [ -f "$f" ] && v="$(git config -f "$f" --bool --get "$key" 2>/dev/null)"; then printf '%s\n' "$v"; return 0; fi
  printf '%s\n' "$def"
}

# skipped <check-name> — true when SAFETY_SKIP (comma/space list) names the check, or "all".
skipped() {
  local list=",${SAFETY_SKIP:-},"
  list="$(printf '%s' "$list" | tr ' ' ',')"
  case "$list" in *",$1,"*|*",all,"*) return 0 ;; esac
  return 1
}

# need_node <check-name> — true when node is available; otherwise warns once and returns 1
# (a missing runtime never blocks a commit: the check is reported as skipped).
need_node() {
  if command -v node >/dev/null 2>&1; then return 0; fi
  echo "⚠️  git-safety-hooks: node not found — $1 skipped" >&2
  return 1
}

# chain_local_hook <hook-name> [args…] — setting core.hooksPath disables .git/hooks/*. If the
# repo still has an executable hook of the same name there, run it so nothing is silently lost.
# Turn off with `safety.chainLocalHooks=false`. stdin is passed through (pre-push needs it).
# Never chains when running under the pre-commit framework (its .git/hooks shim would call us
# again) or when already inside a chained call.
chain_local_hook() {
  local name="$1"; shift
  [ -z "${PRE_COMMIT:-}" ] && [ -z "${GIT_SAFETY_CHAINED:-}" ] || return 0
  [ "$(cfg_bool chainLocalHooks true)" = "true" ] || return 0
  local common legacy self
  common="$(git rev-parse --git-common-dir 2>/dev/null)" || return 0
  legacy="$common/hooks/$name"
  [ -f "$legacy" ] && [ -x "$legacy" ] || return 0
  self="$(cd -P "$(dirname "$0")" && pwd)/$(basename "$0")"
  legacy="$(cd -P "$(dirname "$legacy")" && pwd)/$name"
  [ "$self" = "$legacy" ] && return 0
  GIT_SAFETY_CHAINED=1 "$legacy" "$@"
}
