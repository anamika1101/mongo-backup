#!/usr/bin/env bash
# scripts/upload.sh
# Uploads a backup archive to Cloudflare R2, verifies its integrity,
# then prunes old backups to enforce the retention policy.
#
# Features:
#   - Uploads archive + checksum file
#   - Re-downloads and verifies SHA-256 checksum after upload
#   - Configurable retention (KEEP_LAST)
#   - Slack + Discord notifications on success and failure
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

# ── Resolve archive info (from backup.sh temp files or env) ───────────────────
ARCHIVE_PATH="${ARCHIVE_PATH:-$(cat /tmp/last_backup_path.txt 2>/dev/null || true)}"
ARCHIVE_NAME="${ARCHIVE_NAME:-$(cat /tmp/last_backup_name.txt 2>/dev/null || true)}"
EXPECTED_CHECKSUM="${EXPECTED_CHECKSUM:-$(cat /tmp/last_backup_checksum.txt 2>/dev/null || true)}"
ARCHIVE_SIZE="${ARCHIVE_SIZE:-$(cat /tmp/last_backup_size.txt 2>/dev/null || echo 'unknown')}"

# ── Validate ──────────────────────────────────────────────────────────────────
if [[ -z "${ARCHIVE_PATH}" || ! -f "${ARCHIVE_PATH}" ]]; then
  echo "❌ ERROR: Archive not found at '${ARCHIVE_PATH}'"
  echo "   Run backup.sh first, or set ARCHIVE_PATH manually."
  notify_all "FAILED" "MongoDB Backup Upload FAILED" \
    "Archive file not found. backup.sh may not have run successfully."
  exit 1
fi

S3_BASE="s3://${R2_BUCKET}/${R2_PREFIX}"
S3_DEST="${S3_BASE}/${ARCHIVE_NAME}"
S3_CHECKSUM_DEST="${S3_BASE}/${ARCHIVE_NAME}.sha256"
CHECKSUM_FILE="${ARCHIVE_PATH}.sha256"

echo "========================================"
echo "  Upload to Cloudflare R2"
echo "  File   : ${ARCHIVE_NAME}"
echo "  Size   : ${ARCHIVE_SIZE}"
echo "  Bucket : ${R2_BUCKET}/${R2_PREFIX}/"
echo "========================================"

# ── Upload archive ────────────────────────────────────────────────────────────
echo ""
echo "▶ Uploading archive..."
aws s3 cp "${ARCHIVE_PATH}" "${S3_DEST}" \
  --endpoint-url "${R2_ENDPOINT}" \
  --no-progress
echo "✅ Archive uploaded → ${S3_DEST}"

# ── Upload checksum file ──────────────────────────────────────────────────────
if [[ -f "${CHECKSUM_FILE}" ]]; then
  echo "▶ Uploading checksum file..."
  aws s3 cp "${CHECKSUM_FILE}" "${S3_CHECKSUM_DEST}" \
    --endpoint-url "${R2_ENDPOINT}" \
    --no-progress
  echo "✅ Checksum file uploaded"
fi

# ── Verify integrity post-upload ──────────────────────────────────────────────
if [[ -n "${EXPECTED_CHECKSUM}" ]]; then
  echo ""
  echo "▶ Verifying upload integrity (downloading to check)..."
  VERIFY_TMP="/tmp/verify-${ARCHIVE_NAME}"

  aws s3 cp "${S3_DEST}" "${VERIFY_TMP}" \
    --endpoint-url "${R2_ENDPOINT}" \
    --no-progress

  ACTUAL_CHECKSUM=$(sha256sum "${VERIFY_TMP}" | awk '{print $1}')
  rm -f "${VERIFY_TMP}"

  if [[ "${ACTUAL_CHECKSUM}" == "${EXPECTED_CHECKSUM}" ]]; then
    echo "✅ Integrity verified — checksums match"
  else
    echo "❌ INTEGRITY CHECK FAILED"
    echo "   Expected : ${EXPECTED_CHECKSUM}"
    echo "   Actual   : ${ACTUAL_CHECKSUM}"
    notify_all "FAILED" "MongoDB Backup Integrity FAILED" \
      "Uploaded file checksum does not match. Backup may be corrupted. File: ${ARCHIVE_NAME}"
    exit 1
  fi
else
  echo "⚠️  No expected checksum provided — skipping post-upload verification"
fi

# ── Retention policy: prune old backups ───────────────────────────────────────
echo ""
echo "▶ Applying retention policy (keep last ${KEEP_LAST})..."

# List all backup archives sorted oldest-first
ALL_BACKUPS=$(
  aws s3 ls "${S3_BASE}/" \
    --endpoint-url "${R2_ENDPOINT}" \
  | awk '{print $4}' \
  | grep -E '\.(tar\.gz|tar\.gz\.gpg)$' \
  | sort
)

TOTAL=$(echo "${ALL_BACKUPS}" | grep -c '.' 2>/dev/null || echo 0)
echo "   Total backups in R2: ${TOTAL}"

if (( TOTAL > KEEP_LAST )); then
  TO_DELETE=$(( TOTAL - KEEP_LAST ))
  echo "   🗑  Deleting ${TO_DELETE} oldest backup(s)..."

  echo "${ALL_BACKUPS}" | head -n "${TO_DELETE}" | while IFS= read -r OLD_FILE; do
    [[ -z "${OLD_FILE}" ]] && continue
    # Delete archive
    aws s3 rm "${S3_BASE}/${OLD_FILE}" \
      --endpoint-url "${R2_ENDPOINT}" > /dev/null
    # Delete its checksum (ignore if doesn't exist)
    aws s3 rm "${S3_BASE}/${OLD_FILE}.sha256" \
      --endpoint-url "${R2_ENDPOINT}" 2>/dev/null > /dev/null || true
    echo "   🗑  Deleted: ${OLD_FILE}"
  done
else
  echo "   Nothing to prune."
fi

# ── Success notification ──────────────────────────────────────────────────────
notify_all "SUCCESS" "MongoDB Backup Succeeded" \
  "File: ${ARCHIVE_NAME}\nSize: ${ARCHIVE_SIZE}\nBucket: ${R2_BUCKET}/${R2_PREFIX}/"

echo ""
echo "🏁 Upload complete."
