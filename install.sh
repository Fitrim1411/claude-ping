#!/bin/bash
# Claude Ping — installer for macOS.
# Run:  bash install.sh
set -euo pipefail
cd "$(dirname "$0")"

bold() { printf "\033[1m%s\033[0m\n" "$*"; }
ok()   { printf "  \033[32m✓\033[0m %s\n" "$*"; }
warn() { printf "  \033[33m!\033[0m %s\n" "$*"; }

bold "Claude Ping — installing"

# 1) Hammerspoon
if [ -d "/Applications/Hammerspoon.app" ] || [ -d "$HOME/Applications/Hammerspoon.app" ]; then
  ok "Hammerspoon is already installed"
elif command -v brew >/dev/null 2>&1; then
  bold "Installing Hammerspoon with Homebrew…"
  brew install --cask hammerspoon
  ok "Hammerspoon installed"
else
  warn "Hammerspoon is not installed. Download it from https://www.hammerspoon.org,"
  warn "move it to Applications, then run this installer again."
  exit 1
fi

# 2) Hammerspoon module
mkdir -p "$HOME/.hammerspoon"
cp claude_ping.lua "$HOME/.hammerspoon/claude_ping.lua"
INIT="$HOME/.hammerspoon/init.lua"
touch "$INIT"
if ! grep -q 'hs.ipc' "$INIT"; then
  printf '\nrequire("hs.ipc")  -- Claude Ping: `hs` command-line tool for testing\n' >> "$INIT"
  ok "Enabled the hs command-line tool (require(\"hs.ipc\") in init.lua)"
fi
if grep -q 'require("claude_ping")' "$INIT"; then
  ok "init.lua already loads Claude Ping"
else
  printf '\n-- Claude Ping: big reminder when Claude is done\nClaudePing = require("claude_ping")\nClaudePing.start()\n' >> "$INIT"
  ok "Added Claude Ping to ~/.hammerspoon/init.lua"
fi

# 3) Claude Code hooks (VS Code, terminal, background sessions)
mkdir -p "$HOME/.claude/hooks"
cp claude-ping.sh "$HOME/.claude/hooks/claude-ping.sh"
cp claude-usage.sh "$HOME/.claude/hooks/claude-usage.sh"
chmod +x "$HOME/.claude/hooks/claude-ping.sh" "$HOME/.claude/hooks/claude-usage.sh"
ok "Scripts installed in ~/.claude/hooks/ (claude-ping.sh, claude-usage.sh)"

SETTINGS="$HOME/.claude/settings.json"
if [ -f "$SETTINGS" ]; then
  BACKUP="$SETTINGS.backup-$(date +%Y%m%d-%H%M%S)"
  cp "$SETTINGS" "$BACKUP"
  ok "Backed up your settings: $BACKUP"
fi
if osascript -l JavaScript merge-settings.js "$SETTINGS" >/dev/null; then
  ok "Added hooks to ~/.claude/settings.json (your other hooks are untouched)"
else
  warn "Could not read settings.json automatically (it may contain comments or non-standard JSON)."
  warn "Copy the contents of hooks-snippet.json into its \"hooks\" section by hand."
fi

# 4) Restart Hammerspoon so the module loads
osascript -e 'quit app "Hammerspoon"' >/dev/null 2>&1 || true
sleep 1
open -a Hammerspoon
ok "Hammerspoon started"

echo
bold "Almost done — two one-time steps:"
echo "  1. If Hammerspoon asks for Accessibility access, click Open System Settings and turn it on."
echo "     (Needed for the Claude Desktop Chat and Code tabs.)"
echo "  2. Click the ◌ icon in the menu bar → 'Show a test reminder'. A green border means it works."
echo
echo "  Claude Code picks up the new hooks automatically. If an already-open session doesn't, restart it once."
echo "  The usage meter (% of the 5-hour limit · time left) appears in the menu bar within a few seconds."
echo "  'Launch Hammerspoon at login' is turned on so reminders survive a restart (uncheck it in Hammerspoon's Preferences)."
echo "  For Safari/Chrome: install claude-ping.user.js (see README.md)."
