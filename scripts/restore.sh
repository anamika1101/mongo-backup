#!/usr/bin/env bash
# scripts/restore.sh
# Downloads a backup from Cloudflare R2, verifies its integrity,
# decrypts it (if encrypted), and restores the MongoDB database.
#
# Usage:
#   ./scripts/restore.sh                          # restore latest backup
#   ./scripts/restore.sh <filename>               # restore specific backup
#   DRY_RUN=true ./scripts/restore.sh             # list backups, no restore
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/notify.sh
source "${SCRIPT_DIR}/notify.sh"

# ── Required config ───────────────────────────────────────────────────────────
: "${MONGO_URI:?ERROR: MONGO_URI is not set}"
: "${R2_ENDPOINT:?ERROR: R2_ENDPOINT is not set}"
: "${R2_BUCKET:?ERROR: R2_BUCKET is not set}"

# ── Optional config ───────────────────────────────────────────────────────────
R2_PREFIX="${R2_PREFIX:-backups}"
RESTORE_DIR="${RESTORE_DIR:-/tmp/mongo-restore}"
DRY_RUN="${DRY_RUN:-false}"
BACKUP_ENCRYPTION_KEY="${BACKUP_ENCRYPTION_KEY:-}"

S3_BASE="s3://${R2_BUCKET}/${R2_PREFIX}"

echo "========================================"
echo "  MongoDB Restore from Cloudflare R2"
echo "========================================"

# ── List available backups ────────────────────────────────────────────────────
echo ""
echo "▶ Available backups (oldest → newest):"

AVAILABLE=$(
  aws s3 ls "${S3_BASE}/" \
    --endpoint-url "${R2_ENDPOINT}" \
  | awk '{print $4}' \
  | grep -E '\.(tar\.gz|tar\.gz\.gpg)$' \
  | sort
)

if [[ -z "${AVAILABLE}" ]]; then
  echo "❌ No backups found in ${S3_BASE}/"
  exit 1
fi

echo "${AVAILABLE}" | nl -ba
echo ""

# ── Dry run: just list, then exit ────────────────────────────────────────────
if [[ "${DRY_RUN}" == "true" ]]; then
  TOTAL=$(echo "${AVAILABLE}" | grep -c '.' || echo 0)
  echo "ℹ️  DRY_RUN=true — found ${TOTAL} backup(s). No restore performed."
  exit 0
fi

# ── Resolve target backup ─────────────────────────────────────────────────────
if [[ -n "${1:-}" ]]; then
  TARGET_FILE="$1"
  # Validate it exists in R2
  if ! echo "${AVAILABLE}" | grep -qx "${TARGET_FILE}"; then
    echo "❌ ERROR: '${TARGET_FILE}' not found in R2."
    echo "   Run with DRY_RUN=true to list available backups."
    exit 1
  fi
  echo "📂 Using specified backup: ${TARGET_FILE}"
else
  TARGET_FILE=$(echo "${AVAILABLE}" | tail -n 1)
  echo "📂 Using latest backup: ${TARGET_FILE}"
fi

# ── Safety warning ────────────────────────────────────────────────────────────
echo ""
echo "┌─────────────────────────────────────────────┐"
echo "│  ⚠️  WARNING: This will DROP all existing    │"
echo "│  collections before restoring from backup.  │"
echo "│  Press ENTER to continue, Ctrl+C to abort.  │"
echo "└─────────────────────────────────────────────┘"
# 10s timeout so CI/CD pipelines auto-continue; humans can Ctrl+C
read -t 10 -r || true
echo ""

# ── Download ──────────────────────────────────────────────────────────────────
mkdir -p "${RESTORE_DIR}"
LOCAL_ARCHIVE="${RESTORE_DIR}/${TARGET_FILE}"

echo "▶ Downloading ${TARGET_FILE}..."
aws s3 cp \
  "${S3_BASE}/${TARGET_FILE}" \
  "${LOCAL_ARCHIVE}" \
  --endpoint-url "${R2_ENDPOINT}"
echo "✅ Downloaded"

# ── Verify checksum ───────────────────────────────────────────────────────────
echo ""
echo "▶ Verifying integrity..."
LOCAL_CHECKSUM_FILE="${LOCAL_ARCHIVE}.sha256"

if aws s3 cp "${S3_BASE}/${TARGET_FILE}.sha256" "${LOCAL_CHECKSUM_FILE}" \
    --endpoint-url "${R2_ENDPOINT}" 2>/dev/null; then

  EXPECTED_CHECKSUM=$(awk '{print $1}' "${LOCAL_CHECKSUM_FILE}")
  ACTUAL_CHECKSUM=$(sha256sum "${LOCAL_ARCHIVE}" | awk '{print $1}')

  if [[ "${EXPECTED_CHECKSUM}" == "${ACTUAL_CHECKSUM}" ]]; then
    echo "✅ Integrity check PASSED"
  else
    echo "❌ CHECKSUM MISMATCH — backup is corrupted, aborting."
    echo "   Expected : ${EXPECTED_CHECKSUM}"
    echo "   Actual   : ${ACTUAL_CHECKSUM}"
    notify_all "FAILED" "MongoDB Restore FAILED" \
      "Checksum mismatch on ${TARGET_FILE} — backup may be corrupted."
    rm -rf "${RESTORE_DIR}"
    exit 1
  fi
else
  echo "⚠️  No checksum file found in R2 — skipping integrity check"
fi

# ── Decrypt (if .gpg) ─────────────────────────────────────────────────────────
RESTORE_ARCHIVE="${LOCAL_ARCHIVE}"

if [[ "${TARGET_FILE}" == *.gpg ]]; then
  if [[ -z "${BACKUP_ENCRYPTION_KEY}" ]]; then
    echo "❌ ERROR: Backup is encrypted (.gpg) but BACKUP_ENCRYPTION_KEY is not set."
    rm -rf "${RESTORE_DIR}"
    exit 1
  fi

  echo ""
  echo "▶ Decrypting backup..."
  DECRYPTED_PATH="${LOCAL_ARCHIVE%.gpg}"

  gpg --batch \
      --yes \
      --passphrase "${BACKUP_ENCRYPTION_KEY}" \
      --decrypt \
      --output "${DECRYPTED_PATH}" \
      "${LOCAL_ARCHIVE}" 2>/dev/null

  RESTORE_ARCHIVE="${DECRYPTED_PATH}"
  echo "✅ Decrypted successfully"
fi

# ── Extract ───────────────────────────────────────────────────────────────────
echo ""
echo "▶ Extracting archive..."
tar -xzf "${RESTORE_ARCHIVE}" -C "${RESTORE_DIR}"

# Find the extracted dump directory (mongodump creates a named subdirectory)
DUMP_DIR=$(find "${RESTORE_DIR}" -mindepth 1 -maxdepth 1 -type d | sort | head -n 1)
if [[ -z "${DUMP_DIR}" ]]; then
  echo "❌ ERROR: Could not find extracted dump directory inside ${RESTORE_DIR}"
  rm -rf "${RESTORE_DIR}"
  exit 1
fi
echo "✅ Extracted to: ${DUMP_DIR}"

# ── Restore ───────────────────────────────────────────────────────────────────
echo ""
echo "▶ Running mongorestore..."
mongorestore \
  --uri="${MONGO_URI}" \
  --dir="${DUMP_DIR}" \
  --gzip \
  --drop \
  --quiet

echo "✅ Database restored from: ${TARGET_FILE}"
notify_all "SUCCESS" "MongoDB Restore Succeeded" "Restored from: ${TARGET_FILE}"

# ── Cleanup ───────────────────────────────────────────────────────────────────
echo ""
echo "▶ Cleaning up temp files..."
rm -rf "${RESTORE_DIR}"
echo "🏁 Restore finished."
