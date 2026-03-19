/**
 * dashboard/worker.js
 * 
 * Cloudflare Worker that acts as an authenticated proxy for R2 bucket listing.
 * Deploy this if your bucket is PRIVATE and you can't use public access.
 *
 * Deploy steps:
 *   1. Install Wrangler: npm install -g wrangler
 *   2. Login: wrangler login
 *   3. Edit the BUCKET_NAME and ALLOWED_ORIGIN below
 *   4. Deploy: wrangler deploy dashboard/worker.js
 *   5. Use the Worker URL in the dashboard instead of the R2 public URL
 *
 * The Worker uses your R2 binding — credentials never leave Cloudflare.
 */

// ── Config ────────────────────────────────────────────────────────────────────
const BUCKET_NAME = "mongo-backups";      // Your R2 bucket name
const PREFIX      = "backups/";           // Prefix to list
const ALLOWED_ORIGIN = "*";              // Restrict to your domain in production
                                          // e.g. "https://your-dashboard-domain.com"

// ── Wrangler config (wrangler.toml) ───────────────────────────────────────────
// Create this file alongside worker.js:
//
// name = "mongo-backup-dashboard"
// main = "dashboard/worker.js"
// compatibility_date = "2024-01-01"
//
// [[r2_buckets]]
// binding = "BUCKET"
// bucket_name = "mongo-backups"

// ── Worker handler ────────────────────────────────────────────────────────────
export default {
  async fetch(request, env) {
    // CORS preflight
    if (request.method === "OPTIONS") {
      return new Response(null, {
        headers: corsHeaders(),
      });
    }

    if (request.method !== "GET") {
      return new Response("Method not allowed", { status: 405 });
    }

    try {
      // List objects in the R2 bucket with our prefix
      const listed = await env.BUCKET.list({
        prefix: PREFIX,
        limit: 1000,
      });

      // Build S3-compatible XML response so the dashboard JS works unchanged
      const objects = listed.objects
        .filter(obj => obj.key.match(/\.(tar\.gz|tar\.gz\.gpg)$/))
        .sort((a, b) => new Date(a.uploaded) - new Date(b.uploaded));

      const xml = buildXML(objects);

      return new Response(xml, {
        headers: {
          "Content-Type": "application/xml",
          ...corsHeaders(),
        },
      });
    } catch (err) {
      return new Response(
        `<Error><Code>InternalError</Code><Message>${err.message}</Message></Error>`,
        { status: 500, headers: { "Content-Type": "application/xml", ...corsHeaders() } }
      );
    }
  },
};

function corsHeaders() {
  return {
    "Access-Control-Allow-Origin": ALLOWED_ORIGIN,
    "Access-Control-Allow-Methods": "GET, OPTIONS",
    "Access-Control-Allow-Headers": "Content-Type",
  };
}

function buildXML(objects) {
  const contents = objects.map(obj => `
  <Contents>
    <Key>${escapeXml(obj.key)}</Key>
    <LastModified>${new Date(obj.uploaded).toISOString()}</LastModified>
    <Size>${obj.size}</Size>
    <ETag>"${obj.etag || ''}"</ETag>
  </Contents>`).join("");

  return `<?xml version="1.0" encoding="UTF-8"?>
<ListBucketResult>
  <Name>${escapeXml(BUCKET_NAME)}</Name>
  <Prefix>${escapeXml(PREFIX)}</Prefix>
  <MaxKeys>1000</MaxKeys>
  <IsTruncated>false</IsTruncated>
  ${contents}
</ListBucketResult>`;
}

function escapeXml(str) {
  return String(str)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}
