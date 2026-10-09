#!/bin/bash
# Claude Ping — remove everything.
# Run:  bash uninstall.sh
set -uo pipefail
cd "$(dirname "$0")"

SETTINGS="$HOME/.claude/settings.json"
if [ -f "$SETTINGS" ]; then
  cp "$SETTINGS" "$SETTINGS.backup-$(date +%Y%m%d-%H%M%S)"
  osascript -l JavaScript merge-settings.js "$SETTINGS" --remove >/dev/null \
    && echo "✓ Removed Claude Ping hooks from settings.json" \
    || echo "! Remove the lines containing claude-ping.sh from $SETTINGS by hand"
fi

rm -f "$HOME/.claude/hooks/claude-ping.sh" "$HOME/.claude/hooks/claude-usage.sh" \
      "$HOME/.claude/hooks/.claude-usage-last" "$HOME/.hammerspoon/claude_ping.lua"
INIT="$HOME/.hammerspoon/init.lua"
if [ -f "$INIT" ]; then
  # Matches both the current English lines and the older Indonesian ones.
  sed -i '' -e '/Claude Ping: big reminder/d' -e '/Claude Ping: penanda besar/d' \
    -e '/require("claude_ping")/d' -e '/^ClaudePing\.start()/d' \
    -e '/Claude Ping: `hs` command-line tool/d' -e '/Claude Ping: CLI `hs`/d' "$INIT"
fi
echo "✓ Removed Claude Ping files"

osascript -e 'quit app "Hammerspoon"' >/dev/null 2>&1 || true
sleep 1
open -a Hammerspoon >/dev/null 2>&1 || true
echo "✓ Done. Remove the userscript from Userscripts/Tampermonkey if you installed it."
