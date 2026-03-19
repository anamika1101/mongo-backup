#!/usr/bin/env bash
# scripts/daily-report.sh
# Generates a daily backup summary and sends it to Slack, Discord, and/or
# email via SendGrid. Designed to be run once daily by GitHub Actions.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/notify.sh
source "${SCRIPT_DIR}/notify.sh"

# ── Required config ───────────────────────────────────────────────────────────
: "${R2_ENDPOINT:?ERROR: R2_ENDPOINT is not set}"
: "${R2_BUCKET:?ERROR: R2_BUCKET is not set}"

# ── Optional config ───────────────────────────────────────────────────────────
R2_PREFIX="${R2_PREFIX:-backups}"
KEEP_LAST="${KEEP_LAST:-14}"
SENDGRID_API_KEY="${SENDGRID_API_KEY:-}"
REPORT_EMAIL_TO="${REPORT_EMAIL_TO:-}"
REPORT_EMAIL_FROM="${REPORT_EMAIL_FROM:-backup-bot@example.com}"

TODAY=$(date -u +"%Y-%m-%d")
S3_BASE="s3://${R2_BUCKET}/${R2_PREFIX}"

echo "========================================"
echo "  Daily Backup Report — ${TODAY}"
echo "========================================"

# ── Gather all backup entries from R2 ────────────────────────────────────────
echo "▶ Querying R2..."

RAW_LIST=$(
  aws s3 ls "${S3_BASE}/" \
    --endpoint-url "${R2_ENDPOINT}" \
  | grep -E '\.(tar\.gz|tar\.gz\.gpg)$' \
  | sort
)

TOTAL_COUNT=$(echo "${RAW_LIST}" | grep -c '.' 2>/dev/null || echo 0)

if [[ "${TOTAL_COUNT}" -eq 0 ]]; then
  MSG="No backups found in ${S3_BASE}/"
  echo "⚠️  ${MSG}"
  notify_all "WARNING" "Daily Backup Report — ${TODAY}" "${MSG}"
  exit 0
fi

# ── Parse latest backup ───────────────────────────────────────────────────────
LATEST_LINE=$(echo "${RAW_LIST}" | tail -n 1)
LATEST_NAME=$(echo "${LATEST_LINE}" | awk '{print $4}')
LATEST_DATE=$(echo "${LATEST_LINE}" | awk '{print $1}')   # format: 2026-03-08
LATEST_TIME=$(echo "${LATEST_LINE}" | awk '{print $2}')   # format: 12:00:00
LATEST_SIZE_BYTES=$(echo "${LATEST_LINE}" | awk '{print $3}')
LATEST_SIZE_KB=$(( LATEST_SIZE_BYTES / 1024 ))

# ── Parse oldest backup ───────────────────────────────────────────────────────
OLDEST_NAME=$(echo "${RAW_LIST}" | head -n 1 | awk '{print $4}')

# ── Calculate total storage ───────────────────────────────────────────────────
# Sum all backup file sizes (only archives, not .sha256 files)
TOTAL_BYTES=$(
  aws s3 ls "${S3_BASE}/" \
    --endpoint-url "${R2_ENDPOINT}" \
  | grep -E '\.(tar\.gz|tar\.gz\.gpg)$' \
  | awk '{sum += $3} END {printf "%d", sum}'
)
TOTAL_MB=$(echo "scale=2; ${TOTAL_BYTES} / 1048576" | bc)

# ── Calculate how many hours ago the latest backup was ───────────────────────
# Use python3 for date math (portable, no macOS/Linux differences)
HOURS_AGO=$(python3 -c "
from datetime import datetime, timezone
latest_str = '${LATEST_DATE} ${LATEST_TIME}'
latest = datetime.strptime(latest_str, '%Y-%m-%d %H:%M:%S').replace(tzinfo=timezone.utc)
now = datetime.now(timezone.utc)
diff_hours = (now - latest).total_seconds() / 3600
print(int(diff_hours))
")

# ── Determine health status ───────────────────────────────────────────────────
if (( HOURS_AGO <= 13 )); then
  STATUS="Healthy"
  STATUS_ICON="✅"
  NOTIFY_TYPE="SUCCESS"
elif (( HOURS_AGO <= 25 )); then
  STATUS="Warning — last backup ${HOURS_AGO}h ago"
  STATUS_ICON="⚠️"
  NOTIFY_TYPE="WARNING"
else
  STATUS="CRITICAL — last backup ${HOURS_AGO}h ago"
  STATUS_ICON="❌"
  NOTIFY_TYPE="FAILED"
fi

# ── Build report text ─────────────────────────────────────────────────────────
REPORT=$(cat <<EOF
${STATUS_ICON} Status       : ${STATUS}
📦 Total Backups : ${TOTAL_COUNT} (retaining last ${KEEP_LAST})
💾 Total Storage : ${TOTAL_MB} MB
🕐 Latest Backup : ${LATEST_NAME}
   Size           : ${LATEST_SIZE_KB} KB  |  Age: ${HOURS_AGO}h ago
📅 Oldest Backup : ${OLDEST_NAME}
EOF
)

echo ""
echo "${REPORT}"
echo ""

# ── Send to Slack ─────────────────────────────────────────────────────────────
notify_all "${NOTIFY_TYPE}" "Daily Backup Report — ${TODAY}" "${REPORT}"

# ── Send email via SendGrid ───────────────────────────────────────────────────
if [[ -n "${SENDGRID_API_KEY}" && -n "${REPORT_EMAIL_TO}" ]]; then
  echo "▶ Sending email to ${REPORT_EMAIL_TO}..."

  SUBJECT="[${STATUS_ICON} ${STATUS}] MongoDB Backup Report — ${TODAY}"
  HTML_BODY="<html><body><pre style='font-family:monospace'>${REPORT}</pre></body></html>"

  # Build JSON payload safely with python3
  EMAIL_PAYLOAD=$(python3 -c "
import json, sys
to_email, from_email, subject, html_body = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
print(json.dumps({
  'personalizations': [{'to': [{'email': to_email}]}],
  'from': {'email': from_email},
  'subject': subject,
  'content': [{'type': 'text/html', 'value': html_body}]
}))
" "${REPORT_EMAIL_TO}" "${REPORT_EMAIL_FROM}" "${SUBJECT}" "${HTML_BODY}")

  HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST "https://api.sendgrid.com/v3/mail/send" \
    -H "Authorization: Bearer ${SENDGRID_API_KEY}" \
    -H "Content-Type: application/json" \
    --data "${EMAIL_PAYLOAD}")

  if [[ "${HTTP_STATUS}" == "202" ]]; then
    echo "✅ Email sent (HTTP ${HTTP_STATUS})"
  else
    echo "⚠️  Email may have failed (HTTP ${HTTP_STATUS})"
  fi
fi

echo "🏁 Daily report complete."
