#!/usr/bin/env python3
"""Post-processes the vendored vscode-web bundle for same-origin serving.

The webview host page (out/vs/workbench/contrib/webview/browser/pre/index.html)
unconditionally validates that its hostname equals a hash of parentOrigin —
designed for the per-webview {{uuid}}.vscode-cdn.net scheme. Served same-origin
(http://localhost) that check throws, `webview-ready` never fires, and every
webview (markdown preview etc.) stays blank. code-server patches the identical
check (patches/webview.diff); we apply the same bypass to the file we serve and
recompute the CSP sha256 of the modified inline script.

Idempotent; run by fetch-vscode-web.sh after download.
"""

import base64
import hashlib
import re
import sys
from pathlib import Path

BYPASS = """
				// PATCHED (ios wrapper): same-host serving is safe — the webview
				// shares the workbench origin by design here. Mirrors
				// code-server's patches/webview.diff.
				if (parentOrigin && new URL(parentOrigin).hostname === hostname) {
					return start(parentOrigin);
				}
"""

ANCHOR = "\t\t\t\tconst hostname = location.hostname;\n"


def main() -> None:
    root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent / "Vendor/vscode-web"
    page = root / "out/vs/workbench/contrib/webview/browser/pre/index.html"
    html = page.read_text(encoding="utf-8")

    if "PATCHED (ios wrapper)" in html:
        print("webview pre/index.html already patched")
        return

    # Insert the bypass inside signalReady(), right after hostname is read and
    # before the crypto.subtle validation.
    occurrences = html.count(ANCHOR)
    if occurrences != 1:
        sys.exit(f"expected exactly one hostname anchor in {page}, found {occurrences} — upstream changed, update this script")
    html = html.replace(ANCHOR, ANCHOR + BYPASS)

    # Recompute the CSP hash of the (single) inline script.
    scripts = re.findall(r"<script[^>]*>(.*?)</script>", html, flags=re.DOTALL)
    if len(scripts) != 1:
        sys.exit(f"expected exactly one inline <script> in {page}, found {len(scripts)}")
    digest = base64.b64encode(hashlib.sha256(scripts[0].encode("utf-8")).digest()).decode()

    html, hashes_replaced = re.subn(r"'sha256-[A-Za-z0-9+/=]+'", f"'sha256-{digest}'", html, count=1)
    if hashes_replaced != 1:
        sys.exit(f"could not find CSP sha256 hash to replace in {page}")

    page.write_text(html, encoding="utf-8")
    print(f"patched {page} (new CSP hash sha256-{digest})")


if __name__ == "__main__":
    main()
