import WebKit

/// Native endpoint for the `ipad-files` web extension's file operations.
///
/// The extension runs in a Web Worker (no `window.webkit`), so it talks to the
/// main frame over a same-origin `BroadcastChannel`; our injected `bridge.js`
/// relays each request to this reply-capable message handler. This transport is
/// deliberately NOT `fetch`-based: BroadcastChannel isn't governed by CSP, so it
/// needs no `connect-src` allowance (no nginx tweak, no code-server patch).
///
/// Message body: { op, params: {…}, data: <base64 | null> }
/// Reply: { ok: true, … } on success, or { ok: false, status, error }.
/// Binary payloads (read/write) are base64 to stay within message-reply types.
final class FileBridgeMessageHandler: NSObject, WKScriptMessageHandlerWithReply {
    static let name = "fileBridge"

    private let store = LocalFileStore.shared

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        let reply: ([String: Any]) -> Void = { result in
            DispatchQueue.main.async { replyHandler(result, nil) }
        }

        guard let body = message.body as? [String: Any], let op = body["op"] as? String else {
            reply(["ok": false, "status": 400, "error": "malformed message"])
            return
        }
        let params = body["params"] as? [String: String] ?? [:]
        let dataBase64 = body["data"] as? String
        let id = params["id"] ?? ""
        let path = params["path"] ?? ""

        switch op {
        case "pick-folder":
            store.pickFolder { result in
                switch result {
                case .success(let folder): reply(["ok": true, "id": folder.id, "name": folder.name])
                case .failure(let error): reply(Self.errorPayload(error))
                }
            }
            return
        case "roots":
            reply(["ok": true, "roots": store.roots().map { ["id": $0.id, "name": $0.name] }])
            return
        default:
            break
        }

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                switch op {
                case "stat":
                    var result = try self.store.stat(rootId: id, path: path)
                    result["ok"] = true
                    reply(result)
                case "list":
                    reply(["ok": true, "entries": try self.store.list(rootId: id, path: path)])
                case "read":
                    let data = try self.store.read(rootId: id, path: path)
                    reply(["ok": true, "bytes": data.base64EncodedString()])
                case "write":
                    let data = Data(base64Encoded: dataBase64 ?? "") ?? Data()
                    try self.store.write(rootId: id, path: path, data: data)
                    reply(["ok": true])
                case "mkdir":
                    try self.store.makeDirectory(rootId: id, path: path)
                    reply(["ok": true])
                case "delete":
                    try self.store.delete(rootId: id, path: path)
                    reply(["ok": true])
                case "rename":
                    try self.store.rename(rootId: id, from: params["from"] ?? "", to: params["to"] ?? "")
                    reply(["ok": true])
                default:
                    reply(["ok": false, "status": 404, "error": "unknown op \(op)"])
                }
            } catch {
                reply(Self.errorPayload(error))
            }
        }
    }

    private static func errorPayload(_ error: Error) -> [String: Any] {
        let status: Int
        switch error {
        case FileBridgeError.notFound: status = 404
        case FileBridgeError.unknownRoot: status = 410
        case FileBridgeError.cancelled: status = 499
        case FileBridgeError.noPresenter: status = 503
        default:
            let nsError = error as NSError
            status = (nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileReadNoSuchFileError) ? 404 : 500
        }
        return ["ok": false, "status": status, "error": "\(error)"]
    }
}
