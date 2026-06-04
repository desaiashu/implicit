#!/usr/bin/env bash
#
# Deploy the Censor Audio download site to Cloudflare Pages and the app zip to
# Cloudflare R2. Requires wrangler, authenticated (`wrangler login` once, or set
# CLOUDFLARE_API_TOKEN). Re-run any time to publish a new build.
#
#   ./deploy-site.sh

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BUCKET="censor-audio"
PROJECT="censor-audio"
ZIP="$HERE/CensorAudio.zip"
KEY="CensorAudio.zip"

WR="${WRANGLER:-wrangler}"
command -v "$WR" >/dev/null || { echo "error: wrangler not found. Install: npm i -g wrangler  (then: wrangler login)" >&2; exit 1; }
[[ -f "$ZIP" ]] || { echo "error: $ZIP not found — build it with ./run.sh first." >&2; exit 1; }

echo "==> R2: ensure bucket + upload the app ($(du -h "$ZIP" | cut -f1))"
"$WR" r2 bucket create "$BUCKET" 2>/dev/null || echo "    (bucket already exists)"
"$WR" r2 object put "$BUCKET/$KEY" --file "$ZIP" --content-type "application/zip"

echo "==> R2: enable the public dev URL"
"$WR" r2 bucket dev-url enable "$BUCKET" 2>/dev/null || true
PUB="$("$WR" r2 bucket dev-url get "$BUCKET" 2>/dev/null | grep -oE 'https://[A-Za-z0-9.-]+' | head -1 || true)"
if [[ -z "$PUB" ]]; then
  echo "    couldn't read the public URL automatically — enable it in the R2 dashboard"
  echo "    (bucket → Settings → Public access → r2.dev) and set DOWNLOAD_URL below by hand."
  PUB="https://REPLACE-WITH-PUBLIC-R2-URL"
fi
DOWNLOAD_URL="${DOWNLOAD_URL:-$PUB/$KEY}"
echo "    download URL: $DOWNLOAD_URL"

echo "==> Pages: build site with the download URL and deploy"
BUILD="$HERE/.site-build"
rm -rf "$BUILD"; mkdir -p "$BUILD"
cp -R "$HERE/site/." "$BUILD/"
sed -i '' "s#__DOWNLOAD_URL__#${DOWNLOAD_URL//#/\\#}#" "$BUILD/index.html"
"$WR" pages project create "$PROJECT" --production-branch main 2>/dev/null || true
"$WR" pages deploy "$BUILD" --project-name "$PROJECT" --commit-dirty=true

echo "==> Pages: attach custom domain censor.audio (zone is on this account)"
"$WR" pages domain add censor.audio --project-name "$PROJECT" 2>/dev/null \
  || echo "    (already attached, or add it in Dashboard → Pages → $PROJECT → Custom domains)"

echo
echo "Done."
echo "  • Site:     https://censor.audio  (also https://$PROJECT.pages.dev)"
echo "  • Download: $DOWNLOAD_URL"
echo
echo "Nicer download URL (optional): attach a custom domain to the R2 bucket"
echo "(Dashboard → R2 → $BUCKET → Settings → Custom domains, e.g. dl.censor.audio),"
echo "then re-run with DOWNLOAD_URL=https://dl.censor.audio/$KEY ./deploy-site.sh"
