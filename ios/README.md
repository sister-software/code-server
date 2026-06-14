# Code for iPad

A native iPad app that runs **VS Code itself** — no longer just a shell around
a remote code-server. The app hosts Microsoft's prebuilt serverless web
workbench (the same bits that power vscode.dev) from an in-process HTTP
server, edits local iPad/iCloud folders through a native bridge, installs
extensions from the official marketplace, and attaches to a development box
over SSH with full remote parity (server-side extension host, terminals).
Connecting to a plain code-server URL still works and shares the same shell.

Personal/dev use only: the workbench bundle and vscode-server are Microsoft-
licensed product builds, and the app is signed with a personal team.

## Why native (and not a PWA or React Native)

iOS forces every web view onto WebKit, so we can't ship a better engine — but a
native host gets the escape hatches a web app can't:

- **Clipboard** — bridge `navigator.clipboard` (and `clipboard.write()`) to `UIPasteboard`.
- **Keyboard** — no Safari chrome stealing `Cmd-W`/`T`/`N`; the iPad
  input-assistant bar is suppressed at the `WKContentView` class level.
- **Jetsam** — detect web-content-process kills and auto-restore.
- **Local server + SSH sockets** — the serverless workbench and the native
  Remote-SSH replacement are impossible in a browser tab.

React Native would sit between us and exactly these native APIs while adding
nothing at the web-view layer (it wraps the same `WKWebView`), so this is plain
Swift + UIKit.

## Layout

| Path | What |
|---|---|
| `CodeServerClient/App` | UIKit shell: scene/root wiring, SSH orchestration |
| `CodeServerClient/Connection` | server list UI + persistence (URLs, SSH target) |
| `CodeServerClient/Web` | `WebViewController` (the persistent WKWebView), `WorkbenchServer` (loopback HTTP), input-assistant suppression |
| `CodeServerClient/Files` | `LocalFileStore` (security-scoped bookmarks), `fileBridge` message handler |
| `CodeServerClient/Remote` | native SSH remoting: NIO SSH session, device key, host-key pinning |
| `CodeServerClient/Resources` | `bridge.js` (injected), `workbench.html` + `workbench-main.js` (host page + bootstrap) |
| `Vendor/` | gitignored: `vscode-web` bundle + staged `ipad-files` extension |
| `scripts/` | `fetch-vscode-web.sh` (download/stage vendors), `patch-vscode-web.py` (same-origin fixups) |
| `../ipad-files/` | web extension (`ipadfs:` FileSystemProvider, clipboard helpers) — ships as a builtin |

## Build & run

```sh
brew install xcodegen git-lfs libimobiledevice   # one-time
cd ios
./scripts/fetch-vscode-web.sh                    # stage Vendor/ (re-run to bump VS Code)
xcodegen                                         # generate the .xcodeproj (gitignored)
xcodebuild -project CodeServerClient.xcodeproj -scheme CodeServerClient \
  -configuration Debug -destination 'generic/platform=iOS' \
  -allowProvisioningUpdates build
xcrun devicectl device install app --device <DEVICE-ID> <DerivedData>/Code.app
xcrun devicectl device process launch --device <DEVICE-ID> software.sister.codeserverclient
```

Install-in-place only — uninstalling wipes the web view's storage (logins,
workbench state). Signing team is baked into `project.yml`.

## How the local workbench works

`WorkbenchServer` (FlyingFox) listens on loopback `:9180` (v4 + v6) and serves:

- `/` — `Resources/workbench.html` with `{{WORKBENCH_WEB_CONFIGURATION}}`
  filled natively: product config (official marketplace gallery), builtin
  extensions, webview endpoint, optional remote authority.
- `/boot/main.js` — bootstrap (adapted from `@vscode/test-web`, MIT) that reads
  the config meta tag and calls the workbench's `create()`. **The prebuilt
  bundle ships no bootstrap of its own.**
- `/static/*` — the `Vendor/vscode-web` tree
- `/ipad-files/*` — the builtin extension (`additionalBuiltinExtensions`)
- `/callback` — URL-callback flows

Local files: the `ipad-files` extension (web worker) ⇄ `BroadcastChannel`
⇄ `bridge.js` relay (top frame) ⇄ `fileBridge` native handler ⇄
security-scoped bookmarks. BroadcastChannel because the worker has no
`window.webkit` and fetch() to custom schemes is CSP-blocked; it is
same-origin scoped, which drives several constraints below.

## How SSH remoting works

The Remote-SSH *extension* can never run here (it's a Node extension; web
workbenches have no local extension host). `SSHRemoteSession` does the same
dance natively:

1. SwiftNIO SSH connection. Auth: the device's own ed25519 key (generated
   on-device, Keychain-held; "Copy Public Key" in the connect dialog →
   `authorized_keys`), password fallback. Host keys are pinned on first use;
   re-saving the address forgets the pin.
2. A long-running exec bootstraps the **official vscode-server at the exact
   commit of the bundled workbench** (`Vendor/vscode-web/ios-commit.txt`,
   written by `patch-vscode-web.py`; the remote protocol requires matching
   commits) into `~/.ipad-vscode-server/<commit>` on the host and starts it on
   the host's loopback with a one-shot connection token. The server lives and
   dies with the SSH session.
3. Each connection to a local forward port is bridged over an SSH
   `direct-tcpip` channel. The workbench boots with
   `remoteAuthority: "localhost:<port>"`.

Suspension kills the sockets; on foreground the app reconnects silently with
the device key and rebinds the same port so the workbench's reconnect banner
resumes the session.

## Controls

- **Cmd + Opt + ,** — Servers list (Local Workbench / SSH Remote / saved URLs).
- **Cmd + Opt + R** — reload the page.
- **Two-finger long press** — Reload / Hard Reload / Servers / **Diagnostics**
  (async page probe → alert; the only "console" available untethered).
- **Command palette** (local workbench) — the same four actions as
  `iPad: Reload Web View / Hard Reload Web View / Servers… / Diagnostics`, for
  when the two-finger gesture is awkward (e.g. the Simulator).

## WebKit traps (hard-won; read before touching)

- **Service workers exist only for app-bound domains.** `WKAppBoundDomains:
  [localhost]` + `limitsNavigationsToAppBoundDomains = true` on the local web
  view only. Remote-server views must stay unbound or SSO redirects break.
  Hence `http://localhost:9180`, never `127.0.0.1` (IPs can't be app-bound,
  and loopback aliases are distinct origins with separate state).
- **Everything must stay same-origin.** Null `webEndpointUrlTemplate` in
  product config (extension-host iframe) AND set the `webviewEndpoint`
  construction option (webviews — the environment service re-defaults to
  vscode-cdn.net even when the product template is null). Cross-origin iframes
  can't register service workers in WKWebView (→ blank webviews), and the
  BroadcastChannel bridge only reaches a same-origin worker host.
- **The webview host page validates `hostname == hash(parentOrigin)`** (built
  for `{{uuid}}.vscode-cdn.net`). `patch-vscode-web.py` applies the same-host
  bypass (mirrors code-server's `patches/webview.diff`) and recomputes the CSP
  script hash. Re-applied automatically by the fetch script.
- **VS Code's clipboard is DOM-event based.** Never intercept Cmd-C/X/V
  natively. The `navigator.clipboard` shim must also intercept `write()`:
  VS Code's WebKit gesture workaround routes every `writeText` through a
  pre-armed ClipboardItem, and WebKit's ClipboardItem write eats trailing
  newlines. Empty-selection line copy/cut: WebKit fires no copy/cut event on a
  collapsed selection — the extension keybindings dispatch a synthetic
  ClipboardEvent at Monaco's textarea so VS Code's real handler runs (and
  stores the metadata that makes paste insert line-above).
- **The iPad input-assistant bar** must be neutralized at the `WKContentView`
  class level (`inputAssistantItem` getter override): hardware-key focus with
  no touch builds the bar before any keyboard notification fires.
- **No console on device.** `os_log`/`NSLog` don't reliably reach
  `idevicesyslog`. Use Diagnostics, or Safari Web Inspector when tethered
  (`isInspectable` is on). Crash reports: `idevicecrashreport`.
- **NIO promises must complete on every teardown path** — never-active
  channels skip `channelInactive` (`handlerRemoved` is the last guaranteed
  callback); NIO asserts on promises leaked at deinit. SSH child channels can
  be active before handlers join the pipeline (send exec from `handlerAdded`
  when already active).
- **LAN sockets require `NSLocalNetworkUsageDescription`** or iOS denies the
  connect silently.

## Known limitations

- "Open Folder" toolbar button is dead in **serverless** sessions (WebKit has
  no File System Access API; same on vscode.dev in Safari). Use the palette:
  "iPad: Open Local Folder…". With an SSH remote attached, Open Folder works
  (remote picker).
- Remote - SSH / other Node extensions can't install "in browser" — install on
  the remote instead (official marketplace, works).
- SSH auth: device key or password; no OpenSSH certificate / agent support yet.
- Keyboard combos iOS itself owns (Globe, `Cmd-Space`, `Cmd-H`, `Cmd-Tab`)
  can't be reclaimed.
- Self-signed certs are trusted unconditionally — personal lab tool; tighten
  before sharing.
