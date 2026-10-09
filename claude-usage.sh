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

RAW=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null) || exit 1
TOK=$(printf '%s' "$RAW" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
RAW=""
[ -n "$TOK" ] || exit 1

# The token goes to curl on stdin (not as an argument), so it never shows up in the process list.
printf 'header = "Authorization: Bearer %s"\n' "$TOK" | curl -s -f -m 8 -K - \
  -H "anthropic-beta: oauth-2025-04-20" "https://api.anthropic.com/api/oauth/usage" |
jq -c 'def win: select(. != null and .utilization != null)
         | { used_percentage: .utilization,
             resets_at: (.resets_at | sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | fromdateiso8601) };
       { five_hour: (.five_hour | win), seven_day: (.seven_day | win),
         breakdown: [ (.seven_day_breakdown.rows // [])[] | select(.percent > 0)
                      | { name: .display_name, pct: .percent } ] }' 2>/dev/null
