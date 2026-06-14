import WebKit

/// Native endpoint for the ipad-files terminal — a vscode.Pseudoterminal wired
/// to the iSH x86-Linux emulator (full Alpine, offline). Pure passthrough:
/// Alpine's real shell handles prompt/echo/line-editing, so every keystroke
/// flows raw to the guest and all guest output streams back.
///
/// Transport mirrors the file bridge: BroadcastChannel("ipad-terminal") ⇄
/// bridge.js ⇄ this reply handler; output is pushed via
/// window.__ipadTerminalPush(id, kind, base64).
final class TerminalBridgeHandler: NSObject, WKScriptMessageHandlerWithReply {
    static let name = "terminal"

    weak var webView: WKWebView?

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
            IshTerminal.shared.open(id: id, cols: cols, rows: rows) { [weak self] data in
                if let data {
                    self?.push(id: id, kind: "data", data: data)
                } else {
                    self?.push(id: id, kind: "exit", data: Data("0".utf8))
                }
            }
            replyHandler(["ok": true], nil)
        case "stdin":
            if let b64 = body["data"] as? String, let data = Data(base64Encoded: b64) {
                IshTerminal.shared.input(id: id, data)
            }
            replyHandler(["ok": true], nil)
        case "resize":
            if let cols = body["cols"] as? Int, let rows = body["rows"] as? Int {
                IshTerminal.shared.resize(id: id, cols: cols, rows: rows)
            }
            replyHandler(["ok": true], nil)
        case "close":
            IshTerminal.shared.close(id: id)
            replyHandler(["ok": true], nil)
        default:
            replyHandler(["ok": false, "error": "unknown op \(op)"], nil)
        }
    }

    private func push(id: Int, kind: String, data: Data) {
        let b64 = data.base64EncodedString()
        let js = "window.__ipadTerminalPush && window.__ipadTerminalPush(\(id), '\(kind)', '\(b64)')"
        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript(js, completionHandler: nil)
        }
    }
}
