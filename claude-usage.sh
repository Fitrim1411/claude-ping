#!/bin/bash
# Claude Ping — fetch Claude usage (5-hour and weekly windows) for the menu bar meter.
#
# Hammerspoon runs  claude-usage.sh --fetch  right after Claude finishes (terminal, VS Code,
# Claude Desktop, browser), when the meter's menu is opened, and at reset time; at most once
# a minute. It makes one request to the same Anthropic usage endpoint that /usage uses,
# signed in with Claude Code's login from the macOS Keychain. The token is never stored or
# sent anywhere else. Prints compact JSON.
# Needs jq (built into macOS 15 and later at /usr/bin/jq).

[ "${1:-}" = "--fetch" ] || exit 0

# Use the real home folder from the user database: `security` finds the login keychain
# through $HOME, which can be wrong when Hammerspoon was started from another shell.
REAL_HOME=$(dscl . -read "/Users/$(id -un)" NFSHomeDirectory 2>/dev/null | sed 's/^NFSHomeDirectory: //')
[ -d "$REAL_HOME" ] && export HOME="$REAL_HOME"

# Exit codes, explained in the meter's menu: 1 = can't read Claude Code's login,
# 3 = Claude Code's login has expired, 4 = the request failed, 5 = unexpected answer.
RAW=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null) || exit 1
TOK=$(printf '%s' "$RAW" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
EXP=$(printf '%s' "$RAW" | jq -r '.claudeAiOauth.expiresAt // 0 | floor / 1000 | floor' 2>/dev/null)
RAW=""
[ -n "$TOK" ] || exit 1

# The login expires after some hours without Claude Code (e.g. overnight, or a morning spent in
# Claude Desktop). Only Claude Code may renew it (renewing it here would sign Claude Code out),
# and it does so by itself the next time it runs. Until then the server would refuse it.
[ "${EXP:-0}" -gt 0 ] && [ "${EXP:-0}" -le "$(date +%s)" ] && exit 3

# The token goes to curl on stdin (not as an argument), so it never shows up in the process list.
BODY=$(printf 'header = "Authorization: Bearer %s"\n' "$TOK" | curl -s -f -m 8 -K - \
  -H "anthropic-beta: oauth-2025-04-20" "https://api.anthropic.com/api/oauth/usage") || exit 4
TOK=""
printf '%s' "$BODY" |
jq -c 'def win: if . == null or .utilization == null then null   # a missing window must not empty the output
         else { used_percentage: .utilization,
                resets_at: (.resets_at | if . == null then null   # null right after a reset, until you use Claude again
                              else sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | fromdateiso8601 end) } end;
       { five_hour: (.five_hour | win), seven_day: (.seven_day | win),
         breakdown: [ (.seven_day_breakdown.rows // [])[] | select(.percent > 0)
                      | { name: .display_name, pct: .percent } ] }' 2>/dev/null || exit 5
