import WebKit

/// Native endpoint for the ipad-files extension's offline terminal — a
/// vscode.Pseudoterminal bridged to ios_system (a-Shell's engine).
///
/// Transport mirrors the file bridge: the extension (web worker) talks over a
/// same-origin BroadcastChannel("ipad-terminal"); bridge.js relays control
/// messages to this reply-capable handler, and output is pushed back by calling
/// `window.__ipadTerminalPush(id, kind, base64)` in the main frame. Payloads are
/// base64 to avoid string-escaping pitfalls.
///
/// Message: { op, id, ... }. Ops: open(cols,rows), input(dataBase64),
/// resize(cols,rows), close.
final class TerminalBridgeHandler: NSObject, WKScriptMessageHandlerWithReply {
    static let name = "terminal"

    weak var webView: WKWebView?

    private var sessions: [Int: TerminalSession] = [:]
    private let lock = NSLock()

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        guard let body = message.body as? [String: Any],
              let op = body["op"] as? String,
              let id = body["id"] as? Int else {
            replyHandler(["ok": false, "error": "bad message"], nil)
            return
        }

        switch op {
        case "open":
            let cols = body["cols"] as? Int ?? 80
            let rows = body["rows"] as? Int ?? 24
            open(id: id, cols: cols, rows: rows, reply: replyHandler)
        case "run":
            if let b64 = body["data"] as? String, let data = Data(base64Encoded: b64),
               let text = String(data: data, encoding: .utf8) {
                session(id)?.runCommand(text)
            }
            replyHandler(["ok": true], nil)
        case "stdin":
            if let b64 = body["data"] as? String, let data = Data(base64Encoded: b64),
               let text = String(data: data, encoding: .utf8) {
                session(id)?.writeInput(text)
            }
            replyHandler(["ok": true], nil)
        case "interrupt":
            session(id)?.interrupt()
            replyHandler(["ok": true], nil)
        case "resize":
            if let cols = body["cols"] as? Int, let rows = body["rows"] as? Int {
                session(id)?.resize(cols: cols, rows: rows)
            }
            replyHandler(["ok": true], nil)
        case "close":
            lock.lock(); let s = sessions.removeValue(forKey: id); lock.unlock()
            s?.requestExit()
            replyHandler(["ok": true], nil)
        default:
            replyHandler(["ok": false, "error": "unknown op \(op)"], nil)
        }
    }

    private func session(_ id: Int) -> TerminalSession? {
        lock.lock(); defer { lock.unlock() }
        return sessions[id]
    }

    private func open(id: Int, cols: Int, rows: Int, reply: @escaping (Any?, String?) -> Void) {
        lock.lock()
        guard sessions[id] == nil else {
            lock.unlock()
            reply(["ok": false, "error": "terminal \(id) already open"], nil)
            return
        }
        let session = TerminalSession(id: id, cols: cols, rows: rows)
        session.onData = { [weak self] data in self?.push(id: id, kind: "data", text: data) }
        session.onReady = { [weak self] in self?.push(id: id, kind: "ready", text: "") }
        session.onExit = { [weak self] code in
            self?.push(id: id, kind: "exit", text: String(code))
            self?.lock.lock(); self?.sessions.removeValue(forKey: id); self?.lock.unlock()
        }
        guard session.start() else {
            lock.unlock()
            reply(["ok": false, "error": "failed to start shell"], nil)
            return
        }
        sessions[id] = session
        lock.unlock()
        reply(["ok": true], nil)
    }

    /// Push an event to the extension via the main-frame relay. Data is base64
    /// so arbitrary terminal bytes survive the JS string round-trip.
    private func push(id: Int, kind: String, text: String) {
        let b64 = Data(text.utf8).base64EncodedString()
        let js = "window.__ipadTerminalPush && window.__ipadTerminalPush(\(id), '\(kind)', '\(b64)')"
        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    func killAll() {
        lock.lock(); let all = sessions; sessions.removeAll(); lock.unlock()
        for (_, s) in all { s.forceKill() }
    }
}
