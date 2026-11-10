# shellcheck shell=bash
# agent-detect.sh — "which tool is making this commit?". Source it, then call `detect_agent`
# (prints claude-code|cursor|codex|human|unknown, or any value you set explicitly).
#
# Order (first hit wins):
#   1. $GIT_AGENT                explicit override (any non-empty value)
#   2. `git config safety.agent` per-repo / per-worktree setting
#   3. CLAUDECODE=1              => claude-code
#   4. CURSOR_AGENT or CURSOR_TRACE_ID set => cursor
#   5. CODEX_SANDBOX / CODEX_THREAD_ID / CODEX_CI set => codex
#   6. a TTY on stdin or stderr  => human
#   7. otherwise                 => unknown
#
# Notes:
#   * CODEX_HOME is deliberately NOT tested: other tools' environments can export it, and it
#     would label unrelated commits "codex".
#   * The Cursor/Codex variable names are best-effort, not from authoritative docs. If a tool
#     ships under a different variable, set GIT_AGENT or `git config safety.agent` instead —
#     both outrank the guess.
#   * Claude is tested before Cursor/Codex on purpose: a Claude Code session launched from a
#     Cursor terminal inherits CURSOR_* and is still Claude Code.

detect_agent() {
  local v
  v="${GIT_AGENT:-}"
  if [ -n "$v" ]; then echo "$v"; return 0; fi
  v="$(git config --get safety.agent 2>/dev/null || true)"
  if [ -n "$v" ]; then echo "$v"; return 0; fi
  if [ "${CLAUDECODE:-}" = "1" ]; then echo claude-code; return 0; fi
  if [ -n "${CURSOR_AGENT:-}" ] || [ -n "${CURSOR_TRACE_ID:-}" ]; then echo cursor; return 0; fi
  if [ -n "${CODEX_SANDBOX:-}" ] || [ -n "${CODEX_THREAD_ID:-}" ] || [ -n "${CODEX_CI:-}" ]; then echo codex; return 0; fi
  if [ -t 0 ] || [ -t 2 ]; then echo human; return 0; fi
  echo unknown
}

# If executed directly, print the answer (handy for debugging).
if [ "${BASH_SOURCE[0]}" = "$0" ]; then detect_agent; fi
