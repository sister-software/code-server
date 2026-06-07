# ipad-files

A VS Code **web extension** that exposes iPad/iCloud local files inside
code-server, bridged through the native iOS wrapper (see `../ios`).

## How it works

code-server's extension host runs on the *server*, which can't see your iPad's
files. Only code running in the browser can reach the native bridge — so this
ships as a **web extension** (`extensionKind: ["web"]`, `browser` entry), which
VS Code runs in the in-browser **Web Worker** extension host even when a remote
server is present.

It registers a `FileSystemProvider` for the `ipadfs:` scheme. The command
**iPad: Open Local Folder…** asks native to show the document picker; the chosen
folder is added to the workspace as `ipadfs:/<bookmarkId>`, and every file
operation flows to the device.

### Transport (the important bit)

A Web Worker has no `window.webkit.messageHandlers`, and `fetch()` to a custom
scheme would be blocked by the worker host's CSP (`connect-src`). So instead:

```
extension (Web Worker)  ──BroadcastChannel('ipadfs-bridge')──▶  bridge.js (main frame)
                                                                     │ window.webkit.messageHandlers.fileBridge (reply)
                                                                     ▼
                                                              native LocalFileStore
```

`BroadcastChannel` is **not** governed by CSP and is shared across same-origin
contexts, so this needs **no `connect-src` allowance** — no nginx tweak, no
code-server patch. It relies on code-server serving the worker host on the same
origin as the workbench (which it does).

## Build

```sh
npm install
npm run build      # esbuild → dist/extension.js
npm run typecheck
npm run package    # → ipad-files.vsix  (needs @vscode/vsce)
```

## Install on code-server

```sh
code-server --install-extension ipad-files.vsix
```

Then reload the web app. Run **iPad: Open Local Folder…** from the command
palette (only meaningful inside the iOS wrapper, which serves the native bridge).

## Verifying the architecture (first run)

This is the spike that confirms we can skip a custom code-server build:

1. The extension activates (check the running-extensions view; it should be in
   the **Web Worker** host, not the remote host).
2. Running the command opens the iOS document picker (proves Worker →
   BroadcastChannel → main frame → native works, i.e. same-origin holds).
3. The picked folder appears in the Explorer and files open/save.

If (1) fails, code-server isn't starting the web worker host for installed
extensions → bundle this as a built-in via a patch (custom build). If (2) fails,
the worker host isn't same-origin → fall back to the `fetch`/`ipadbridge://`
transport plus a CSP allowance.
