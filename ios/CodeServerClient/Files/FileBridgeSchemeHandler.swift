import WebKit

/// Serves the `ipadbridge://` scheme that the `ipad-files` web extension fetches
/// from its Web Worker (where `window.webkit` is unavailable, so a URL scheme is
/// the transport). Requests map to `LocalFileStore` operations.
///
/// Protocol (host = operation, params in query, body = bytes for writes):
///   ipadbridge://pick-folder                      -> { id, name }
///   ipadbridge://roots                            -> { roots: [{id,name}] }
///   ipadbridge://stat?id=&path=                   -> { type, size, mtime, ctime }
///   ipadbridge://list?id=&path=                   -> { entries: [{name,type}] }
///   ipadbridge://read?id=&path=                   -> raw bytes
///   ipadbridge://write?id=&path=   (POST body)    -> { ok: true }
///   ipadbridge://mkdir?id=&path=   (POST)         -> { ok: true }
///   ipadbridge://delete?id=&path=  (POST)         -> { ok: true }
///   ipadbridge://rename?id=&from=&to= (POST)      -> { ok: true }
final class FileBridgeSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "ipadbridge"

    private let store = LocalFileStore.shared
    private let lock = NSLock()
    private var stopped = Set<ObjectIdentifier>()

    private static let corsHeaders = [
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
        "Access-Control-Allow-Headers": "*",
    ]

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            respond(task, status: 400, json: ["error": "bad url"])
            return
        }

        if task.request.httpMethod == "OPTIONS" {
            respond(task, status: 200, json: ["ok": true])
            return
        }

        let op = components.host ?? ""
        let params = Dictionary(
            (components.queryItems ?? []).map { ($0.name, $0.value ?? "") },
            uniquingKeysWith: { first, _ in first }
        )

        switch op {
        case "pick-folder":
            store.pickFolder { [weak self] result in
                switch result {
                case .success(let folder):
                    self?.respond(task, status: 200, json: ["id": folder.id, "name": folder.name])
                case .failure(let error):
                    self?.respondError(task, error)
                }
            }
        case "roots":
            let roots = store.roots().map { ["id": $0.id, "name": $0.name] }
            respond(task, status: 200, json: ["roots": roots])
        default:
            let body = task.request.httpBody ?? Self.readStream(task.request.httpBodyStream)
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.handleFileOp(op, params: params, body: body, task: task)
            }
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        lock.lock()
        stopped.insert(ObjectIdentifier(task as AnyObject))
        lock.unlock()
    }

    // MARK: - Operations

    private func handleFileOp(_ op: String, params: [String: String], body: Data?, task: WKURLSchemeTask) {
        let id = params["id"] ?? ""
        let path = decode(params["path"])
        do {
            switch op {
            case "stat":
                respond(task, status: 200, json: try store.stat(rootId: id, path: path))
            case "list":
                respond(task, status: 200, json: ["entries": try store.list(rootId: id, path: path)])
            case "read":
                respond(task, status: 200, contentType: "application/octet-stream",
                        data: try store.read(rootId: id, path: path))
            case "write":
                try store.write(rootId: id, path: path, data: body ?? Data())
                respond(task, status: 200, json: ["ok": true])
            case "mkdir":
                try store.makeDirectory(rootId: id, path: path)
                respond(task, status: 200, json: ["ok": true])
            case "delete":
                try store.delete(rootId: id, path: path)
                respond(task, status: 200, json: ["ok": true])
            case "rename":
                try store.rename(rootId: id, from: decode(params["from"]), to: decode(params["to"]))
                respond(task, status: 200, json: ["ok": true])
            default:
                respond(task, status: 404, json: ["error": "unknown op \(op)"])
            }
        } catch {
            respondError(task, error)
        }
    }

    // MARK: - Responding

    private func respond(_ task: WKURLSchemeTask, status: Int, json: [String: Any]) {
        let data = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
        respond(task, status: status, contentType: "application/json", data: data)
    }

    private func respond(_ task: WKURLSchemeTask, status: Int, contentType: String, data: Data) {
        DispatchQueue.main.async {
            guard !self.isStopped(task), let url = task.request.url else { return }
            var headers = Self.corsHeaders
            headers["Content-Type"] = contentType
            headers["Content-Length"] = String(data.count)
            guard let response = HTTPURLResponse(
                url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers
            ) else { return }
            task.didReceive(response)
            task.didReceive(data)
            task.didFinish()
        }
    }

    private func respondError(_ task: WKURLSchemeTask, _ error: Error) {
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
        respond(task, status: status, json: ["error": "\(error)"])
    }

    // MARK: - Helpers

    private func isStopped(_ task: WKURLSchemeTask) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped.contains(ObjectIdentifier(task as AnyObject))
    }

    private func decode(_ value: String?) -> String {
        (value ?? "").removingPercentEncoding ?? (value ?? "")
    }

    private static func readStream(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
