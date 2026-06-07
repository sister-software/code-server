# Code Server iOS client

A thin native iPad shell around a self-hosted [code-server](https://github.com/coder/code-server)
instance. The goal is to make the "VS Code in a browser" experience tolerable on
iPad by fixing the things the web sandbox can't: clipboard, keyboard, and the
memory-pressure reloads that wipe your session.

This is a **client only**. It talks to an unmodified code-server running on your
own machine (home lab, Mac, cloud box). The server stays stock; all the cleverness
lives here and in injected JS.

## Why native (and not a PWA or React Native)

iOS forces every web view onto WebKit, so we can't ship a better engine — but a
native host gets the escape hatches a web app can't:

- **Clipboard** — bridge `navigator.clipboard` to `UIPasteboard`.
- **Keyboard** — no Safari chrome stealing `Cmd-W`/`T`/`N`; keystrokes reach VS Code.
- **Jetsam** — detect web-content-process kills and auto-restore instead of a white screen.

React Native would sit between us and exactly these native APIs while adding
nothing at the web-view layer (it wraps the same `WKWebView`), so this is plain
Swift + UIKit.

## Architecture

```
AppDelegate ──> SceneDelegate ──> RootViewController
                                    ├─ ConnectionViewController   (enter server URL)
                                    └─ WebViewController          (the persistent WKWebView)
                                         │
                                         ├─ Resources/bridge.js   (injected @ document-start, all frames)
                                         └─ "clipboard" message handler (reply-capable)
```

- **One long-lived `WKWebView`**, never torn down — buys jetsam resistance over a Safari tab.
- **`bridge.js`** is injected into every frame (incl. VS Code's nested webviews) and
  cooperates with the native side over `window.webkit.messageHandlers`.
- **Login** uses code-server's own web login page; the session cookie persists in the
  default `WKWebsiteDataStore`.

### Native ⇄ page contract

| Channel | Direction | Purpose |
| --- | --- | --- |
| `messageHandlers.clipboard` `{action:"write",text}` | page → native | set `UIPasteboard` |
| `messageHandlers.clipboard` `{action:"read"}` → reply | page → native → page | read `UIPasteboard` (Promise) |
| `window.__codeServerBridge.saveState()` | native → page | snapshot state before likely jetsam |
| `window.__codeServerBridge.restoreState(json)` | native → page | replay state after reload |
| `window.__codeServerBridge.dispatchKey(p)` | native → page | (seam) forward a reclaimed keystroke |

## Build & run

Requires Xcode and [XcodeGen](https://github.com/yonyz/XcodeGen) (the `.xcodeproj`
is generated, not committed).

```sh
brew install xcodegen          # one-time
cd ios
xcodegen generate             # produces CodeServerClient.xcodeproj
open CodeServerClient.xcodeproj
```

In Xcode: select the **CodeServerClient** scheme, set your **Signing Team**
(Automatic), and run on a Simulator or your iPad. On first launch enter your
code-server URL (e.g. `https://code.your-tailnet.ts.net`).

Command-line simulator build (no signing needed):

```sh
xcodebuild -project CodeServerClient.xcodeproj -scheme CodeServerClient \
  -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M5)' build
```

### Transport

Use [Tailscale](https://tailscale.com) between the iPad and your lab: stable
hostname, no port-forwarding, real TLS. The app accepts `http` and self-signed
certificates for dev convenience (see `Info.plist` ATS + the auth-challenge
handler in `WebViewController`).

### Debugging the web side

`WKWebView.isInspectable` is on, so attach Safari **Develop ▸ \<device\> ▸ \<page\>**
to inspect/step through `bridge.js` and the live VS Code page.

## Controls

- **Cmd + Opt + ,** — open connection settings (avoids VS Code's `Cmd+,`).
- **Two-finger long press** — open connection settings without a keyboard.

## Roadmap

- **v1 (this):** native shell, clipboard bridge, keyboard passthrough, jetsam recovery. Remote FS, stock server.
- **v2 — local files inside the editor:** a web-extension `FileSystemProvider`
  (runs in the in-browser extension host so it can reach the native bridge) backed
  by `UIDocumentPicker` + security-scoped bookmarks.
- **v3 (stretch) — offline:** asset caching via `WKURLSchemeHandler` + a local-file mode.

## Known limitations

- Keyboard combos that iOS itself intercepts (Globe, `Cmd-Space`, `Cmd-H`,
  `Cmd-Tab`) can't and shouldn't be reclaimed. The `dispatchKey` seam exists for
  the rare app-reclaimable combo if one turns up.
- Synthesized key forwarding into nested cross-origin webviews (notebooks,
  previews) is the long-tail polish area; v1 relies on natural passthrough.
- Self-signed certs are trusted unconditionally — fine for a personal lab tool,
  tighten before sharing.
