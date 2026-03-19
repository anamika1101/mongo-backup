# MongoDB → Cloudflare R2 Automated Backup

Automated database backup system. Runs every 12 hours via GitHub Actions,
compresses and optionally encrypts your MongoDB data, uploads it to
Cloudflare R2, verifies integrity, and sends you alerts.

---

## Project Structure

```
mongo-backup/
├── .github/
│   └── workflows/
│       └── mongodb-backup.yml   ← GitHub Actions (backup + report + restore-dry-run)
├── dashboard/
│   ├── index.html               ← Browser-based monitoring dashboard
│   └── worker.js                ← Cloudflare Worker (for private buckets)
├── docker/
│   └── init-mongo.js            ← Seeds MongoDB with sample data on first start
├── scripts/
│   ├── notify.sh                ← Shared Slack + Discord notification helper
│   ├── backup.sh                ← mongodump → tarball → encrypt → checksum
│   ├── upload.sh                ← Upload to R2 → verify integrity → prune old
│   ├── restore.sh               ← Download → verify → decrypt → mongorestore
│   └── daily-report.sh          ← Daily summary → Slack / Discord / Email
├── docker-compose.yml           ← Local MongoDB for testing
├── .env.example                 ← All variables documented
└── .gitignore
```

---

## Features

| Feature | Script | How to enable |
|---|---|---|
| Scheduled backup every 12h | `backup.sh` + workflow | Automatic once deployed |
| Multi-database support | `backup.sh` | Set `DATABASES=appdb,userdb` or `all` |
| Auto-retry on failure | `backup.sh` | Set `MAX_RETRIES` + `RETRY_DELAY` |
| GPG AES-256 encryption | `backup.sh` | Set `BACKUP_ENCRYPTION_KEY` |
| SHA-256 integrity verification | `backup.sh` + `upload.sh` | Automatic |
| Upload to Cloudflare R2 | `upload.sh` | Set R2 secrets |
| Post-upload integrity check | `upload.sh` | Automatic |
| Configurable retention | `upload.sh` | Set `KEEP_LAST` |
| Slack notifications | all scripts | Set `SLACK_WEBHOOK` |
| Discord notifications | all scripts | Set `DISCORD_WEBHOOK` |
| Daily email report | `daily-report.sh` | Set `SENDGRID_API_KEY` |
| Monitoring dashboard | `dashboard/index.html` | Open in browser |
| Restore with decrypt + verify | `restore.sh` | Run manually |

---

## Step 1 — Local Setup

```bash
git clone https://github.com/your-username/mongo-backup.git
cd mongo-backup
cp .env.example .env
# Edit .env with your values
```

Start local MongoDB (Docker required):

```bash
docker compose up -d
```

This starts MongoDB on `localhost:27017` with sample `users`, `products`,
and `orders` collections already seeded.

Install tools (Ubuntu/Debian):

```bash
# mongodump + mongorestore
wget -qO - https://www.mongodb.org/static/pgp/server-7.0.asc \
  | sudo gpg --dearmor -o /usr/share/keyrings/mongodb-server-7.0.gpg
echo "deb [ arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb-server-7.0.gpg ] \
  https://repo.mongodb.org/apt/ubuntu jammy/mongodb-org/7.0 multiverse" \
  | sudo tee /etc/apt/sources.list.d/mongodb-org-7.0.list
sudo apt-get update && sudo apt-get install -y mongodb-database-tools gnupg bc

# AWS CLI
pip install awscli
```

Make scripts executable:

```bash
chmod +x scripts/*.sh
```

---

## Step 2 — Test Locally

```bash
source .env

# Run a backup
./scripts/backup.sh

# Upload to R2
./scripts/upload.sh

# Check what's in R2
aws s3 ls s3://$R2_BUCKET/$R2_PREFIX/ --endpoint-url $R2_ENDPOINT | sort

# Send a test daily report
./scripts/daily-report.sh
```

---

## Step 3 — Cloudflare R2 Setup

1. Log in to [dash.cloudflare.com](https://dash.cloudflare.com) → **R2 Object Storage**
2. **Create bucket** → name it `mongo-backups`
3. **Manage R2 API Tokens** → Create token with **Object Read & Write** on your bucket
4. Copy the **Access Key ID**, **Secret Access Key**
5. From the bucket **Settings** tab, copy the **S3 API endpoint URL**

---

## Step 4 — GitHub Actions

### Add Secrets

Go to: **Repository → Settings → Secrets and variables → Actions → New repository secret**

| Secret | Required | Value |
|---|---|---|
| `MONGO_URI` | ✅ | `mongodb://user:pass@host:27017/db` |
| `R2_ACCESS_KEY_ID` | ✅ | From Cloudflare |
| `R2_SECRET_ACCESS_KEY` | ✅ | From Cloudflare |
| `R2_ENDPOINT` | ✅ | `https://<id>.r2.cloudflarestorage.com` |
| `R2_BUCKET` | ✅ | `mongo-backups` |
| `BACKUP_ENCRYPTION_KEY` | Optional | Strong passphrase for AES-256 |
| `SLACK_WEBHOOK` | Optional | Slack incoming webhook URL |
| `DISCORD_WEBHOOK` | Optional | Discord webhook URL |
| `SENDGRID_API_KEY` | Optional | For email reports |
| `REPORT_EMAIL_TO` | Optional | Email recipient |

### Push and Deploy

```bash
git init
git add .
git commit -m "feat: mongodb backup system"
git remote add origin https://github.com/your-username/mongo-backup.git
git push -u origin main
```

### Trigger Manually

**Actions tab → "MongoDB Backup → Cloudflare R2" → Run workflow**

Choose:
- `job: backup` — run a backup now
- `job: report` — send a daily report now
- `job: restore-dry-run` — list available backups

---

## Schedule

| Job | Cron | Runs at |
|---|---|---|
| Backup + Upload | `0 0,12 * * *` | 00:00 UTC and 12:00 UTC |
| Daily Report | `0 8 * * *` | 08:00 UTC every morning |

---

## Restore

```bash
source .env

# Restore latest backup
./scripts/restore.sh

# Restore specific backup
./scripts/restore.sh mongodb-backup-2024-03-15T12-00-00Z.tar.gz.gpg

# List backups without restoring
DRY_RUN=true ./scripts/restore.sh
```

The restore process:
1. Lists all backups in R2
2. Downloads the target file
3. Verifies SHA-256 checksum (aborts if corrupted)
4. Decrypts `.gpg` files automatically
5. Extracts and runs `mongorestore --drop`
6. Cleans up temp files

---

## Dashboard

Open `dashboard/index.html` in your browser.

**For public buckets:**
1. In Cloudflare → R2 → your bucket → **Settings → Public Access → Enable**
2. Copy the public URL (e.g. `https://pub-xxx.r2.dev`)
3. Paste into the dashboard and click Load

**For private buckets:**
Deploy `dashboard/worker.js` as a Cloudflare Worker (see instructions inside the file) and use the Worker URL instead.

---

## Notifications Setup

### Slack
1. [api.slack.com/apps](https://api.slack.com/apps) → Create App → Incoming Webhooks → Enable
2. Add to workspace → copy Webhook URL
3. Set `SLACK_WEBHOOK` in `.env` / GitHub Secrets

### Discord
1. Discord server → channel settings → **Integrations → Webhooks → New Webhook**
2. Copy URL
3. Set `DISCORD_WEBHOOK` in `.env` / GitHub Secrets

### Email (SendGrid)
1. Sign up at [sendgrid.com](https://sendgrid.com) (free: 100 emails/day)
2. **Settings → API Keys → Create** (Mail Send permission)
3. Verify your sender email address in SendGrid
4. Set `SENDGRID_API_KEY`, `REPORT_EMAIL_TO`, `REPORT_EMAIL_FROM`

---

## Troubleshooting

**Workflow doesn't run on schedule**
Push a commit to activate the repo, or trigger manually from the Actions tab.

**`mongodump: command not found`**
Install `mongodb-database-tools` (see Step 1).

**`InvalidAccessKeyId` error**
Verify `R2_ACCESS_KEY_ID` and `R2_SECRET_ACCESS_KEY`. Token needs **Object Read & Write**.

**Dashboard shows failed to load**
Enable Public Access on the R2 bucket, or deploy the Worker for private buckets.

**GPG decryption fails**
The `BACKUP_ENCRYPTION_KEY` used for restore must exactly match the key used during backup.

**Checksum mismatch**
The upload was corrupted. Re-run the backup. The workflow will alert you automatically.
