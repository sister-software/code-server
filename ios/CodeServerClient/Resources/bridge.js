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

  // Preserve richer APIs (ClipboardItem read/write, events) if WebKit exposes them.
  try {
    var existing = navigator.clipboard
    if (existing) {
      if (typeof existing.write === "function") shim.write = existing.write.bind(existing)
      if (typeof existing.read === "function") shim.read = existing.read.bind(existing)
      if (typeof existing.addEventListener === "function")
        shim.addEventListener = existing.addEventListener.bind(existing)
      if (typeof existing.removeEventListener === "function")
        shim.removeEventListener = existing.removeEventListener.bind(existing)
    }
  } catch (e) {
    /* ignore */
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

  var channel = new BroadcastChannel("ipadfs-bridge")
  channel.onmessage = function (event) {
    var msg = event.data
    if (!msg || typeof msg.reqId !== "string" || !msg.op) return // ignore responses/noise
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
