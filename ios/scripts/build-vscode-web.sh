#!/usr/bin/env bash
# Builds the VS Code web workbench from the lib/vscode submodule and stages it
# for the iOS app. We serve a SERVERLESS workbench (like Microsoft's prebuilt),
# so we build VANILLA VS Code (no code-server patches — those assume a remote
# server and require userDataPath/vscode-remote) plus our own iOS patch series
# (patches/ios-*.diff), then post-process the served bundle (webview
# same-origin + commit) via patch-vscode-web.py.
#
# Output: ios/Vendor/vscode-web (gitignored), like fetch-vscode-web.sh produced.
# Prereqs: git submodule update --init lib/vscode; npm install (root + lib/vscode);
#          quilt; node (24.x ideal; works on newer with the skip below).

set -euo pipefail
cd "$(dirname "$0")/../.."   # repo root

export PATH="/opt/homebrew/bin:$PATH"

echo "[1/4] Resetting submodule to vanilla + applying iOS patches…"
git -C lib/vscode reset --hard >/dev/null
git -C lib/vscode clean -fdq
rm -rf .pc
# Apply ONLY our iOS patches (if any). The code-server stack is intentionally
# skipped — it's for the remote-server product, not a serverless web client.
if ls patches/ios-*.diff >/dev/null 2>&1; then
  for p in patches/ios-*.diff; do
    echo "  applying $(basename "$p")"
    patch -p1 -d lib/vscode < "$p"
  done
fi

echo "[2/4] Building vscode-web (gulp vscode-web-min-ci)…"
( cd lib/vscode
  VSCODE_SKIP_NODE_VERSION_CHECK=1 NODE_OPTIONS="--max-old-space-size=8192" \
    VERSION=0.0.0 npx gulp vscode-web-min-ci )

echo "[3/4] Staging → ios/Vendor/vscode-web…"
rm -rf ios/Vendor/vscode-web
cp -R lib/vscode-web ios/Vendor/vscode-web

echo "[4/4] Post-processing (webview same-origin + commit)…"
python3 ios/scripts/patch-vscode-web.py ios/Vendor/vscode-web

echo "Done. Served workbench: ios/Vendor/vscode-web ($(du -sh ios/Vendor/vscode-web | cut -f1)), commit $(cat ios/Vendor/vscode-web/ios-commit.txt)"
