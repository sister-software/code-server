# iOS app — agent guide

A native iPad/iPadOS app (`software.sister.codeserverclient`, product name
**Code**) that hosts a full VS Code **web** workbench locally and edits local
files, runs an offline Linux terminal, and attaches to dev boxes over SSH. It
lives inside the code-server repo but is **not** part of the published
code-server package — it's developed on the `feat/ios-client` branch and reuses
the repo's `lib/vscode` submodule + `quilt` patch infra to build the workbench.

This file is the operational guide for working in `ios/`. For the architecture
narrative and the full list of WebKit traps, read `ios/README.md` first — don't
duplicate it here; update it when behavior it describes changes.

## The iterate loop (build → device)

There is no simulator path: the terminal engine ships as **iphoneos arm64**
static libs (`CodeServerClient/Remote/Ish/*.a`), so a simulator build won't
link. Always build and run on a real device.

```sh
cd ios
xcodegen generate            # regenerate the .xcodeproj after ANY project.yml / file-tree change
DEV=$(xcrun devicectl list devices | awk '/connected/{print $(NF-2); exit}')   # or hardcode your iPad's UDID
xcrun xcodebuild -project CodeServerClient.xcodeproj -scheme CodeServerClient \
  -configuration Debug -destination "id=$DEV" -derivedDataPath build \
  -allowProvisioningUpdates build
xcrun devicectl device install app --device "$DEV" build/Build/Products/Debug-iphoneos/Code.app
```

- **Never `simctl uninstall` / `devicectl uninstall` while iterating** — it wipes
  the WKWebView data store (GitHub login, Settings Sync, workbench state).
  Install-in-place always upgrades cleanly.
- Launch fails with `error 7 (Locked)` if the device is locked — that's fine,
  the install still landed; the user launches it.
- Signing team (`DEVELOPMENT_TEAM`) is baked into `project.yml`.
- To verify a link/compile without a device, build for
  `-destination 'generic/platform=iOS'` (skips signing/install).

## Project generation

`project.yml` (XcodeGen) is the source of truth; **`*.xcodeproj` is gitignored**
— never hand-edit it, edit `project.yml` and re-run `xcodegen generate`. Notable
target settings: the iSH archives are `-force_load`'d (circular deps);
`GCC_PREPROCESSOR_DEFINITIONS` selects the ish-arm64 guest backend
(`GUEST_ARM64`/`ENGINE_ASBESTOS`/`LOG_HANDLER_DPRINTF`); `Assets.xcassets`
carries the app icon + adaptive launch background.

## Vendored toolchains (all gitignored under `Vendor/`)

Three heavy artifacts are staged by scripts and never committed. Re-run after a
clean checkout or `git clean`.

| Artifact | Built by | What |
|---|---|---|
| `Vendor/vscode-web` | `scripts/build-vscode-web.sh` | the served workbench |
| `Vendor/ipad-files-web` | `scripts/build-vscode-web.sh` (+ `../ipad-files`) | builtin extension (`ipadfs:`/`ish:` providers, clipboard/terminal helpers) |
| `Vendor/ish-rootfs` + `Remote/Ish/*.a` | `scripts/build-ish.sh` | terminal engine + arm64 Alpine fakefs |

### Workbench: SOURCE build, not prebuilt

We serve a **serverless** workbench, so we build **vanilla** VS Code web from
`lib/vscode` — *not* with code-server's own patch stack (those assume a remote
server and need `userDataPath`/`vscode-remote`, which white-screens a serverless
page). `build-vscode-web.sh` does: `quilt pop -a` (drop code-server patches) →
apply our `patches/ios-*.diff` (fonts, keybindings, open-folder, terminal) →
`gulp vscode-web-min-ci` → stage → `patch-vscode-web.py` (webview same-origin
bypass + CSP hash + write `ios-commit.txt`). `fetch-vscode-web.sh` is the older
path that downloads Microsoft's prebuilt bundle instead — still works, but can't
carry source customizations.

The `ios-*.diff` workbench patches live in the repo-root `patches/` dir and are
applied on top of vanilla `lib/vscode` only during the iOS build — they are
**not** in `patches/series` (which is code-server's stack).

### Terminal: ios-linuxkit (ish-arm64)

`build-ish.sh` clones `rcarmo/ios-linuxkit` (GPLv3) pinned to a commit, applies
`scripts/ios-linuxkit-gadget-dedup.patch` (upstream defines four Asbestos
gadgets twice → duplicate-symbol link failure under `-force_load`),
cross-compiles arm64 libs, and builds an **arm64** Alpine fakefs. The C bridge
(`Remote/Ish/IshBridge.{c,h}`, driven by `IshTerminal.swift`) boots one guest
and multiplexes terminals + a guest-fs API. Same-arch interpreter (no JIT/RWX) —
runs on stock iOS.

## Source layout (`CodeServerClient/`)

`App` (scene/root wiring, SSH orchestration) · `Connection` (server list +
persistence) · `Web` (`WebViewController` persistent WKWebView, `WorkbenchServer`
loopback HTTP on `:9180`, input-assistant suppression) · `Files`
(`LocalFileStore` security-scoped bookmarks, `FileBridge*`) · `Remote` (NIO SSH
session, device key, host-key pinning, terminal bridge; `Ish/` engine) ·
`Resources` (`bridge.js` injected shim, `workbench.html` + `workbench-main.js`
host page/bootstrap, served verbatim).

## Conventions & landmines

- This app is local-only on `feat/ios-client`; don't fold it into the published
  package, and **never `git add lib/vscode`** from the repo root (submodule).
- Commits are GPG-signed (repo-wide rule).
- WebKit traps are non-obvious and load-bearing — **read the "WebKit traps"
  section of `ios/README.md` before touching** the web view, clipboard,
  app-bound domains, same-origin/webview endpoints, or the input-assistant bar.
- No reliable on-device console: use the **Diagnostics** action (two-finger long
  press → Diagnostics) or Safari Web Inspector when tethered (`isInspectable`).
- When changing anything the README documents (workbench hosting, SSH flow,
  controls, limitations), update `ios/README.md` in the same change.
