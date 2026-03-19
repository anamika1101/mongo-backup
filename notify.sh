#!/usr/bin/env bash
# scripts/notify.sh
# Shared notification helper. Source this file, then call notify_slack or notify_discord.
# Uses python3 to build JSON safely - avoids all shell escaping bugs.

notify_slack() {
  local color="$1"    # good | warning | danger
  local title="$2"
  local message="$3"
  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  [[ -z "${SLACK_WEBHOOK:-}" ]] && return 0

  local payload
  payload=$(python3 -c "
import json, sys
color, title, text, ts = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
print(json.dumps({
  'attachments': [{
    'color': color,
    'title': title,
    'text': text,
    'footer': 'UTC: ' + ts
  }]
}))
" "$color" "$title" "$message" "$timestamp")

  curl -s -X POST "${SLACK_WEBHOOK}" \
    -H 'Content-type: application/json' \
    --data "$payload" \
    --max-time 10 \
    -o /dev/null || echo "⚠️  Slack notification failed (non-fatal)"
}

notify_discord() {
  local title="$1"
  local message="$2"
  local emoji="${3:-ℹ️}"

  [[ -z "${DISCORD_WEBHOOK:-}" ]] && return 0

  local content="${emoji} **${title}**\n${message}"
  local payload
  payload=$(python3 -c "import json,sys; print(json.dumps({'content': sys.argv[1]}))" "$content")

  curl -s -X POST "${DISCORD_WEBHOOK}" \
    -H 'Content-type: application/json' \
    --data "$payload" \
    --max-time 10 \
    -o /dev/null || echo "⚠️  Discord notification failed (non-fatal)"
}

# Convenience: send to both at once
notify_all() {
  local status="$1"   # SUCCESS | FAILED | WARNING
  local title="$2"
  local message="$3"

  local color emoji
  case "$status" in
    SUCCESS) color="good";    emoji="✅" ;;
    FAILED)  color="danger";  emoji="❌" ;;
    WARNING) color="warning"; emoji="⚠️" ;;
    *)       color="good";    emoji="ℹ️" ;;
  esac

  notify_slack  "$color" "${emoji} ${title}" "$message"
  notify_discord "${emoji} ${title}" "$message" ""
}
