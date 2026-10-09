#!/bin/bash
# Claude Ping — forwards Claude Code events to Hammerspoon.
#
# Called by the hooks in ~/.claude/settings.json with one argument:
#   stop | notify | ask | error | prompt | end
# The event payload (JSON from Claude Code) is passed through as-is on stdin.
#
# Always silent and always exits 0: if Hammerspoon isn't running,
# Claude Code keeps working normally with no error message.

EVENT="${1:-stop}"
PORT="${CLAUDE_PING_PORT:-47823}"

# Hints about which app runs this session (VS Code, Claude Desktop, a terminal…)
if [ -n "$VSCODE_PID" ]; then VS=1; else VS=0; fi
HINTS="vscode=${VS};term=${TERM_PROGRAM:-};entry=${CLAUDE_CODE_ENTRYPOINT:-}"

# Some sessions (e.g. background `claude` sessions) don't inherit __CFBundleIdentifier. For
# those, send the parent process chain; Hammerspoon looks for a GUI app in it. Just one `ps`.
PIDS=""
if [ -z "${__CFBundleIdentifier:-}" ]; then
  PIDS=$(ps -A -o pid=,ppid= 2>/dev/null | awk -v p="$PPID" '{ up[$1] = $2 }
    END { n = 0; while (p > 1 && n < 20) { printf "%s ", p; p = up[p]; n++ } }')
fi

curl -s -m 2 -X POST \
  -H "Content-Type: application/json" \
  -H "X-Claude-Ping: 1" \
  -H "X-Ping-Event: ${EVENT}" \
  -H "X-Ping-App: ${__CFBundleIdentifier:-}" \
  -H "X-Ping-Project: ${CLAUDE_PROJECT_DIR:-}" \
  -H "X-Ping-Hints: ${HINTS}" \
  -H "X-Ping-Pids: ${PIDS}" \
  --data-binary @- \
  "http://127.0.0.1:${PORT}/code" >/dev/null 2>&1

exit 0
