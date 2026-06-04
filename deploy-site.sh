#!/usr/bin/env bash
#
# Publish the Censor Audio download: upload the app zip to Cloudflare R2 and
# deploy the download page to Cloudflare Pages, with the download served from
# https://dl.censor.audio/CensorAudio.zip.
#
# Requires wrangler (authenticated: `wrangler login`). Set these env vars for the
# R2 upload + custom domain (R2 → Manage R2 API Tokens gives the S3 keys; the
# zone id is on the censor.audio Overview page):
#   R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY   — S3 keys for the multipart upload
#   R2_ZONE_ID                                — censor.audio zone id (for dl.* domain)
#
#   R2_ACCESS_KEY_ID=… R2_SECRET_ACCESS_KEY=… R2_ZONE_ID=… ./deploy-site.sh

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BUCKET="censor-audio"
PROJECT="censor-audio"
KEY="CensorAudio.zip"
ZIP="$HERE/$KEY"
DL_DOMAIN="${DL_DOMAIN:-dl.censor.audio}"
DOWNLOAD_URL="${DOWNLOAD_URL:-https://$DL_DOMAIN/$KEY}"
ACCOUNT_ID="${R2_ACCOUNT_ID:-8a0ff27d0ad9b0aa3e9ade38ad6be106}"
WR="${WRANGLER:-wrangler}"

command -v "$WR" >/dev/null || { echo "error: wrangler not found (npm i -g wrangler; wrangler login)" >&2; exit 1; }
[[ -f "$ZIP" ]] || { echo "error: $ZIP not found — build it with ./run.sh first." >&2; exit 1; }

echo "==> R2: upload $KEY ($(du -h "$ZIP" | cut -f1))"
if [[ -n "${R2_ACCESS_KEY_ID:-}" && -n "${R2_SECRET_ACCESS_KEY:-}" ]] && command -v rclone >/dev/null; then
  # wrangler's `r2 object put` caps at 300 MiB, so use rclone S3 multipart.
  rclone copyto "$ZIP" ":s3:$BUCKET/$KEY" \
    --s3-provider=Cloudflare \
    --s3-access-key-id="$R2_ACCESS_KEY_ID" \
    --s3-secret-access-key="$R2_SECRET_ACCESS_KEY" \
    --s3-endpoint="https://$ACCOUNT_ID.r2.cloudflarestorage.com" \
    --s3-region=auto --s3-no-check-bucket
else
  echo "    (no R2 S3 creds in env — trying wrangler; this fails for files >300 MiB)"
  "$WR" r2 object put "$BUCKET/$KEY" --file "$ZIP" --content-type "application/zip" --remote
fi

echo "==> R2: attach download domain $DL_DOMAIN"
if [[ -n "${R2_ZONE_ID:-}" ]]; then
  "$WR" r2 bucket domain add "$BUCKET" --domain "$DL_DOMAIN" --zone-id "$R2_ZONE_ID" --min-tls 1.2 -y 2>/dev/null \
    || echo "    ($DL_DOMAIN already attached)"
else
  echo "    (set R2_ZONE_ID to attach $DL_DOMAIN, or add it in R2 → $BUCKET → Settings → Custom domains)"
fi

echo "==> Pages: deploy site with download URL $DOWNLOAD_URL"
BUILD="$HERE/.site-build"
rm -rf "$BUILD"; mkdir -p "$BUILD"; cp -R "$HERE/site/." "$BUILD/"
sed -i '' "s#__DOWNLOAD_URL__#$DOWNLOAD_URL#" "$BUILD/index.html"
"$WR" pages deploy "$BUILD" --project-name "$PROJECT" --commit-dirty=true

echo
echo "Done."
echo "  • Download: $DOWNLOAD_URL"
echo "  • Site:     https://$PROJECT.pages.dev"
echo "  • Apex censor.audio → Dashboard → Pages → $PROJECT → Custom domains (wrangler v4 has no command for it)."
