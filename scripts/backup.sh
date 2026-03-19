#!/usr/bin/env bash
# scripts/backup.sh
# Dumps MongoDB to a compressed, optionally encrypted, checksummed tarball.
#
# Features:
#   - Multi-database support (DATABASES=all or comma-separated list)
#   - Auto-retry with configurable attempts and delay
#   - Optional GPG AES-256 encryption
#   - SHA-256 checksum generation
#   - Slack + Discord notifications
set -euo pipefail

# ── Source shared helpers ─────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/notify.sh
source "${SCRIPT_DIR}/notify.sh"

# ── Required config ───────────────────────────────────────────────────────────
: "${MONGO_URI:?ERROR: MONGO_URI is not set. Export it or add to .env}"

# ── Optional config (with sensible defaults) ──────────────────────────────────
BACKUP_DIR="${BACKUP_DIR:-/tmp/mongo-backup}"
DATABASES="${DATABASES:-all}"              # "all" or "appdb,userdb,analyticsdb"
BACKUP_ENCRYPTION_KEY="${BACKUP_ENCRYPTION_KEY:-}"  # blank = no encryption
MAX_RETRIES="${MAX_RETRIES:-3}"
RETRY_DELAY="${RETRY_DELAY:-15}"           # seconds between retries

# ── Derived values ────────────────────────────────────────────────────────────
TIMESTAMP=$(date -u +"%Y-%m-%dT%H-%M-%SZ")
DUMP_SUBDIR="dump-${TIMESTAMP}"
DUMP_PATH="${BACKUP_DIR}/${DUMP_SUBDIR}"
ARCHIVE_NAME="mongodb-backup-${TIMESTAMP}.tar.gz"
ARCHIVE_PATH="${BACKUP_DIR}/${ARCHIVE_NAME}"

# ── Print header ──────────────────────────────────────────────────────────────
echo "========================================"
echo "  MongoDB Backup"
echo "  Timestamp  : ${TIMESTAMP}"
echo "  Databases  : ${DATABASES}"
echo "  Encrypted  : $([ -n "${BACKUP_ENCRYPTION_KEY}" ] && echo 'YES (GPG AES-256)' || echo 'no')"
echo "  Max retries: ${MAX_RETRIES}"
echo "========================================"

mkdir -p "${DUMP_PATH}"

# ── mongodump with retry ──────────────────────────────────────────────────────
run_mongodump() {
  local attempt=1

  while (( attempt <= MAX_RETRIES )); do
    echo ""
    echo "▶ mongodump attempt ${attempt}/${MAX_RETRIES}..."

    local exit_code=0

    if [[ "${DATABASES}" == "all" ]]; then
      mongodump \
        --uri="${MONGO_URI}" \
        --out="${DUMP_PATH}" \
        --gzip \
        --quiet || exit_code=$?
    else
      IFS=',' read -ra DB_LIST <<< "${DATABASES}"
      for DB in "${DB_LIST[@]}"; do
        DB="$(echo "$DB" | xargs)"   # trim whitespace
        echo "   📦 Dumping database: ${DB}"
        mongodump \
          --uri="${MONGO_URI}" \
          --db="${DB}" \
          --out="${DUMP_PATH}" \
          --gzip \
          --quiet || { exit_code=$?; break; }
      done
    fi

    if (( exit_code == 0 )); then
      echo "✅ mongodump succeeded on attempt ${attempt}"
      return 0
    fi

    echo "⚠️  Attempt ${attempt} failed (exit code ${exit_code})"

    if (( attempt < MAX_RETRIES )); then
      echo "   Retrying in ${RETRY_DELAY}s..."
      sleep "${RETRY_DELAY}"
    fi

    (( attempt++ ))
  done

  echo "❌ mongodump failed after ${MAX_RETRIES} attempt(s)"
  return 1
}

# Run the dump
if ! run_mongodump; then
  notify_all "FAILED" "MongoDB Backup FAILED" \
    "mongodump failed after ${MAX_RETRIES} retries. Check GitHub Actions logs immediately."
  exit 1
fi

# ── Create tarball ────────────────────────────────────────────────────────────
echo ""
echo "▶ Creating tarball: ${ARCHIVE_NAME}"
tar -czf "${ARCHIVE_PATH}" -C "${BACKUP_DIR}" "${DUMP_SUBDIR}"
rm -rf "${DUMP_PATH}"   # clean up raw dump folder
echo "✅ Tarball created"

# ── Encrypt (optional) ────────────────────────────────────────────────────────
FINAL_ARCHIVE="${ARCHIVE_PATH}"
FINAL_NAME="${ARCHIVE_NAME}"

if [[ -n "${BACKUP_ENCRYPTION_KEY}" ]]; then
  echo ""
  echo "▶ Encrypting with GPG AES-256..."
  FINAL_NAME="${ARCHIVE_NAME}.gpg"
  FINAL_ARCHIVE="${BACKUP_DIR}/${FINAL_NAME}"

  gpg --batch \
      --yes \
      --passphrase "${BACKUP_ENCRYPTION_KEY}" \
      --symmetric \
      --cipher-algo AES256 \
      --output "${FINAL_ARCHIVE}" \
      "${ARCHIVE_PATH}" 2>/dev/null

  rm -f "${ARCHIVE_PATH}"   # delete unencrypted copy immediately
  echo "✅ Encrypted → ${FINAL_NAME}"
fi

# ── Generate SHA-256 checksum ─────────────────────────────────────────────────
echo ""
echo "▶ Generating SHA-256 checksum..."
CHECKSUM=$(sha256sum "${FINAL_ARCHIVE}" | awk '{print $1}')
echo "${CHECKSUM}  ${FINAL_NAME}" > "${BACKUP_DIR}/${FINAL_NAME}.sha256"
echo "✅ Checksum: ${CHECKSUM}"

# ── Summary ───────────────────────────────────────────────────────────────────
ARCHIVE_SIZE=$(du -sh "${FINAL_ARCHIVE}" | cut -f1)
echo ""
echo "========================================"
echo "  Backup Complete"
echo "  File     : ${FINAL_NAME}"
echo "  Size     : ${ARCHIVE_SIZE}"
echo "  Checksum : ${CHECKSUM}"
echo "========================================"

# ── Pass values to next script via temp files + GitHub Actions output ─────────
echo "${FINAL_ARCHIVE}" > /tmp/last_backup_path.txt
echo "${FINAL_NAME}"    > /tmp/last_backup_name.txt
echo "${CHECKSUM}"      > /tmp/last_backup_checksum.txt
echo "${ARCHIVE_SIZE}"  > /tmp/last_backup_size.txt

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "archive_path=${FINAL_ARCHIVE}"
    echo "archive_name=${FINAL_NAME}"
    echo "archive_size=${ARCHIVE_SIZE}"
    echo "checksum=${CHECKSUM}"
  } >> "${GITHUB_OUTPUT}"
fi
