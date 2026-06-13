// Injected into every frame of the code-server page at document-start.
//
// This is the web half of the native bridge. It deliberately runs against a
// STOCK code-server — no server patches required. Everything here cooperates
// with the native shell over window.webkit.messageHandlers.
//
// Debug it live: the native app sets WKWebView.isInspectable, so attach Safari's
// Web Inspector (Develop ▸ <device> ▸ <page>) and you can step through this file.
;(function () {
  "use strict"

  if (window.__codeServerBridgeInstalled) return

  var clipboardHandler =
    window.webkit &&
    window.webkit.messageHandlers &&
    window.webkit.messageHandlers.clipboard
  if (!clipboardHandler) return // not running inside the native shell

  window.__codeServerBridgeInstalled = true

  // --- Clipboard: round-trip navigator.clipboard through UIPasteboard ----------
  //
  // WKWebView cripples programmatic navigator.clipboard access (especially reads),
  // which is exactly the path VS Code/Monaco use. We replace it with a shim that
  // defers to the native pasteboard. readText() resolves via the reply-capable
  // message handler, so it stays a real Promise.

  function nativeWrite(text) {
    return clipboardHandler.postMessage({
      action: "write",
      text: text == null ? "" : String(text),
    })
  }

  function nativeRead() {
    return clipboardHandler.postMessage({ action: "read" }).then(function (value) {
      return value == null ? "" : String(value)
    })
  }

  var shim = {
    writeText: function (text) {
      return nativeWrite(text)
    },
    readText: function () {
      return nativeRead()
    },
  }

  // Preserve richer APIs (ClipboardItem read, events) if WebKit exposes them.
  var existing = null
  try {
    existing = navigator.clipboard
    if (existing) {
      if (typeof existing.read === "function") shim.read = existing.read.bind(existing)
      if (typeof existing.addEventListener === "function")
        shim.addEventListener = existing.addEventListener.bind(existing)
      if (typeof existing.removeEventListener === "function")
        shim.removeEventListener = existing.removeEventListener.bind(existing)
    }
  } catch (e) {
    /* ignore */
  }

  // Resolves a ClipboardItem's text/plain payload (string), or null if it has
  // none. The payload may itself be a pending promise (VS Code's gesture
  // workaround passes one), so this settles only when that does.
  function itemText(item) {
    if (!item || typeof item.getType !== "function") return Promise.resolve(null)
    var types = item.types || []
    if (Array.prototype.indexOf.call(types, "text/plain") === -1) return Promise.resolve(null)
    return item.getType("text/plain").then(function (blob) {
      if (typeof blob === "string") return blob
      if (blob && typeof blob.text === "function") return blob.text()
      return null
    })
  }

  // clipboard.write() must ALSO go through UIPasteboard, not just writeText():
  // VS Code detects WebKit (BrowserClipboardService.installWebKitWriteTextWorkaround)
  // and routes every writeText through a ClipboardItem armed on click/keydown to
  // satisfy Safari's user-gesture rule — bypassing our writeText shim. WebKit's
  // async ClipboardItem write also eats the trailing newline of line-copies.
  // Unwrap text/plain items and write them verbatim; delegate anything else
  // (e.g. images) to the real clipboard.
  shim.write = function (items) {
    var list = Array.prototype.slice.call(items || [])
    return Promise.all(list.map(itemText)).then(
      function (texts) {
        for (var i = 0; i < texts.length; i++) {
          if (typeof texts[i] === "string") return nativeWrite(texts[i])
        }
        if (existing && typeof existing.write === "function") {
          return existing.write.call(existing, items)
        }
        throw new DOMException("clipboard write not supported", "NotAllowedError")
      },
      function () {
        // The armed write was superseded by a newer gesture; VS Code expects a
        // NotAllowedError-shaped rejection here and silently ignores it.
        throw new DOMException("clipboard write superseded", "NotAllowedError")
      },
    )
  }

  try {
    Object.defineProperty(navigator, "clipboard", {
      configurable: true,
      enumerable: true,
      get: function () {
        return shim
      },
    })
  } catch (e) {
    // Fall back to patching the existing object in place.
    try {
      navigator.clipboard.writeText = shim.writeText
      navigator.clipboard.readText = shim.readText
    } catch (e2) {
      /* give up; copy/paste falls back to WebKit defaults */
    }
  }

  // --- window.open routing ----------------------------------------------------
  //
  // OAuth (a urlCallbackProvider.create() ran in the last few seconds) goes to
  // the native ASWebAuthenticationSession — real Safari, with password AutoFill
  // and Face ID. Everything else (plain external links) opens in the system
  // browser, so ordinary links aren't trapped in a sign-in sheet.
  var authHandler = window.webkit.messageHandlers.authSession
  var externalHandler = window.webkit.messageHandlers.openExternal
  if (authHandler || externalHandler) {
    var realOpen = window.open ? window.open.bind(window) : null
    window.open = function (url, target, features) {
      try {
        var href = url == null ? "" : String(url)
        if (/^https?:/i.test(href)) {
          var expectingAuth =
            window.__codeAuthExpected && Date.now() - window.__codeAuthExpected < 3000
          if (expectingAuth && authHandler) {
            window.__codeAuthExpected = 0
            authHandler.postMessage({ url: href })
          } else if (externalHandler) {
            externalHandler.postMessage({ url: href })
          }
          // A non-null stand-in so callers don't treat this as a blocked popup.
          return {
            closed: false,
            close: function () {},
            focus: function () {},
            blur: function () {},
            postMessage: function () {},
            location: { href: href },
          }
        }
      } catch (e) {
        /* fall through to native open */
      }
      return realOpen ? realOpen(url, target, features) : null
    }
  }

  // --- Jetsam recovery hooks (native <-> page) --------------------------------
  //
  // The native shell calls saveState() before iOS is likely to kill the web
  // content process, and restoreState() after it reloads. VS Code already
  // restores its own workbench (open editors, hot-exit), so for v1 we only need
  // to preserve scroll position; this is the seam to persist more later.

  window.__codeServerBridge = {
    saveState: function () {
      try {
        return JSON.stringify({
          scrollX: window.scrollX || 0,
          scrollY: window.scrollY || 0,
        })
      } catch (e) {
        return "{}"
      }
    },

    restoreState: function (json) {
      try {
        var state = JSON.parse(json || "{}")
        if (typeof state.scrollX === "number" && typeof state.scrollY === "number") {
          window.scrollTo(state.scrollX, state.scrollY)
        }
      } catch (e) {
        /* ignore */
      }
    },

    // Keyboard forwarding seam (native -> page). Not wired in v1: inside a native
    // shell there is no Safari chrome to steal Cmd-W/T/N, so keystrokes already
    // reach VS Code. Kept here as the extension point for reclaiming any combo
    // iOS itself intercepts.
    dispatchKey: function (p) {
      var target = document.activeElement || document.body
      var info = target && target.tagName ? target.tagName.toLowerCase() : "none"
      try {
        var init = {
          key: p.key,
          code: p.code,
          metaKey: !!p.meta,
          ctrlKey: !!p.ctrl,
          altKey: !!p.alt,
          shiftKey: !!p.shift,
          bubbles: true,
          cancelable: true,
          composed: true,
        }
        ;["keydown", "keyup"].forEach(function (type) {
          var event = new KeyboardEvent(type, init)
          Object.defineProperty(event, "keyCode", { get: function () { return p.keyCode || 0 } })
          Object.defineProperty(event, "which", { get: function () { return p.keyCode || 0 } })
          target.dispatchEvent(event)
        })
      } catch (e) {
        info = "err:" + e
      }
      return info
    },
  }
})()

// --- Local files bridge relay -----------------------------------------------
//
// The ipad-files web extension runs in a Web Worker (no window.webkit). It talks
// to the main frame over a same-origin BroadcastChannel; this relay forwards each
// request to the native `fileBridge` reply handler and posts the result back.
// Runs only in the top frame so there's exactly one relay. BroadcastChannel is
// not CSP-governed, so this needs no connect-src allowance.
;(function () {
  "use strict"

  if (window.top !== window) return // single relay, top frame only
  if (typeof BroadcastChannel === "undefined") return

  var fileBridge =
    window.webkit &&
    window.webkit.messageHandlers &&
    window.webkit.messageHandlers.fileBridge
  if (!fileBridge) return

  var clipboard =
    window.webkit.messageHandlers && window.webkit.messageHandlers.clipboard

  // Synthetic editor copy/cut. WebKit never fires the DOM copy/cut events on a
  // collapsed selection, so VS Code's built-in empty-selection line copy is dead
  // on iPad. Dispatching a synthetic ClipboardEvent at Monaco's hidden textarea
  // runs VS Code's REAL copy handler — which computes the line copy, writes it
  // into our constructed DataTransfer, and stores the in-memory paste metadata
  // that makes a later paste insert line-above (desktop semantics). Cut also
  // schedules the editor's own line deletion. We then push the harvested text
  // into UIPasteboard. The ipad-files extension invokes this and falls back to a
  // plain env.clipboard write if it fails.
  function syntheticEditorClipboard(op) {
    var target = document.activeElement
    if (!target || target.tagName !== "TEXTAREA") {
      return { ok: false, status: 404, error: "no editor textarea focused" }
    }
    var data = new DataTransfer()
    var event = new ClipboardEvent(op === "editor-cut" ? "cut" : "copy", {
      clipboardData: data,
      bubbles: true,
      cancelable: true,
    })
    target.dispatchEvent(event)
    var text = data.getData("text/plain")
    if (!text) return { ok: false, status: 404, error: "editor produced no clipboard data" }
    if (!clipboard) return { ok: false, status: 503, error: "clipboard handler unavailable" }
    return clipboard.postMessage({ action: "write", text: text }).then(function () {
      return { ok: true, length: text.length }
    })
  }

  var channel = new BroadcastChannel("ipadfs-bridge")
  channel.onmessage = function (event) {
    var msg = event.data
    if (!msg || typeof msg.reqId !== "string" || !msg.op) return // ignore responses/noise
    if (msg.op === "editor-copy" || msg.op === "editor-cut") {
      Promise.resolve()
        .then(function () {
          return syntheticEditorClipboard(msg.op)
        })
        .then(
          function (result) {
            channel.postMessage({ reqId: msg.reqId, result: result })
          },
          function (error) {
            channel.postMessage({
              reqId: msg.reqId,
              result: { ok: false, status: 500, error: String(error) },
            })
          },
        )
      return
    }
    fileBridge
      .postMessage({ op: msg.op, params: msg.params || {}, data: msg.bodyBase64 || null })
      .then(
        function (result) {
          channel.postMessage({ reqId: msg.reqId, result: result })
        },
        function (error) {
          channel.postMessage({
            reqId: msg.reqId,
            result: { ok: false, status: 500, error: String(error) },
          })
        },
      )
  }
})()
