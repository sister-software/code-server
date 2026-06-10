#!/usr/bin/env bash
# Stages the vendored web assets the iOS app serves from its local HTTP server:
#
#   Vendor/vscode-web      — Microsoft's prebuilt serverless VS Code web bundle
#                            (the same bits @vscode/test-web and `code serve-web`
#                            use). Not redistributed; personal dev use.
#   Vendor/ipad-files-web  — clean copy of the ipad-files extension (manifest +
#                            dist only), loaded as an additionalBuiltinExtension.
#
# Both are gitignored; re-run this script after `git clean` or to bump the
# workbench version. Pass a version/quality URL suffix to pin, default latest:
#   ./fetch-vscode-web.sh                  # latest stable
#   ./fetch-vscode-web.sh 1.124.0          # pinned version

set -euo pipefail

cd "$(dirname "$0")/.."
mkdir -p Vendor

VERSION="${1:-latest}"
URL="https://update.code.visualstudio.com/${VERSION}/web-standalone/stable"

echo "Fetching vscode-web (${VERSION})…"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
curl -fsSL -o "$tmp/vscode-web.tgz" "$URL"
tar -xzf "$tmp/vscode-web.tgz" -C "$tmp"
rm -rf Vendor/vscode-web
mv "$tmp/vscode-web" Vendor/vscode-web
grep -o '"version": *"[^"]*"' Vendor/vscode-web/package.json | head -1

# Same-origin fixups (webview parentOrigin bypass + CSP hash).
python3 scripts/patch-vscode-web.py Vendor/vscode-web

echo "Staging ipad-files extension…"
rm -rf Vendor/ipad-files-web
mkdir -p Vendor/ipad-files-web
cp ../ipad-files/package.json Vendor/ipad-files-web/
cp -R ../ipad-files/dist Vendor/ipad-files-web/dist

echo "Done. Re-run xcodegen if the folders were missing when the project was generated."
