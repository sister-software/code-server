import FlyingFox
import Foundation

/// Serves the vendored serverless VS Code web workbench (the same prebuilt
/// bundle vscode.dev / `code serve-web` use) from inside the app over
/// loopback HTTP.
///
/// Why an HTTP server and not a WKURLSchemeHandler: service workers don't work
/// on custom schemes, and the workbench needs one for webviews (markdown
/// preview, extension UIs). 127.0.0.1 is a secure context, so everything works.
/// A fixed port keeps the origin — and therefore IndexedDB workbench state —
/// stable across launches.
///
/// Routes (mirroring `code serve-web`'s webClientServer.ts contract):
///   /            workbench.html with {{PLACEHOLDERS}} filled
///   /callback    callback.html (URL-callback auth flows)
///   /static/*    the vscode-web tree
///   /ipad-files/* the bundled ipad-files extension (additionalBuiltinExtension)
final class WorkbenchServer {
    static let shared = WorkbenchServer()

    static let port: UInt16 = 9180
    /// `localhost`, not 127.0.0.1: WKAppBoundDomains needs a domain, and service
    /// workers (webviews) only exist for app-bound domains in WKWebView.
    static var localURL: URL { URL(string: "http://localhost:\(port)/")! }

    /// When set, the workbench boots attached to this remote (an SSH-forwarded
    /// vscode-server on iPad loopback). Takes effect on the next page load.
    struct RemoteConfig {
        let authority: String
        let connectionToken: String
    }

    var remote: RemoteConfig?

    /// Commit of the vendored workbench, written by scripts/patch-vscode-web.py.
    /// vscode-server downloads are keyed by it.
    static var vscodeCommit: String? {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("vscode-web/ios-commit.txt"),
              let commit = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return commit.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var servers: [HTTPServer] = []
    private var tasks: [Task<Void, Never>] = []

    /// Official marketplace endpoints — personal-use arrangement, same as the
    /// EXTENSIONS_GALLERY env var on the user's code-server deployment.
    private static let extensionsGallery: [String: Any] = [
        "serviceUrl": "https://marketplace.visualstudio.com/_apis/public/gallery",
        "itemUrl": "https://marketplace.visualstudio.com/items",
        "resourceUrlTemplate": "https://{publisher}.vscode-unpkg.net/{publisher}/{name}/{version}/{path}",
    ]

    func startIfNeeded() {
        guard tasks.isEmpty else { return }
        guard let webRoot = Bundle.main.resourceURL?.appendingPathComponent("vscode-web"),
              FileManager.default.fileExists(atPath: webRoot.path) else {
            assertionFailure("vscode-web missing from bundle — run ios/scripts/fetch-vscode-web.sh && xcodegen")
            return
        }
        let extensionRoot = Bundle.main.resourceURL!.appendingPathComponent("ipad-files-web")

        // Listen on both loopback stacks: the page loads "localhost", which iOS
        // may resolve to ::1 before 127.0.0.1.
        let servers = [
            HTTPServer(address: try! .inet(ip4: "127.0.0.1", port: Self.port)),
            HTTPServer(address: try! .inet6(ip6: "::1", port: Self.port)),
        ]
        self.servers = servers

        tasks = servers.map { server in
            Task {
                await self.registerRoutes(on: server, webRoot: webRoot, extensionRoot: extensionRoot)
                do {
                    try await server.run()
                } catch {
                    // Port in use or socket failure: surfaced on next connect attempt.
                }
            }
        }
    }

    private func registerRoutes(on server: HTTPServer, webRoot: URL, extensionRoot: URL) async {
        await server.appendRoute("GET /") { [weak self] _ in
            self?.workbenchResponse() ?? HTTPResponse(statusCode: .notFound)
        }
        // Bootstrap module (adapted from @vscode/test-web): reads the config
        // meta tag and calls the workbench's create(). The prebuilt bundle
        // ships no bootstrap of its own — the embedder provides it.
        await server.appendRoute("GET /boot/main.js") { _ in
            guard let url = Bundle.main.url(forResource: "workbench-main", withExtension: "js") else {
                return HTTPResponse(statusCode: .notFound)
            }
            return Self.fileResponse(url)
        }
        await server.appendRoute("GET /callback") { _ in
            Self.fileResponse(webRoot.appendingPathComponent("out/vs/code/browser/workbench/callback.html"))
        }
        await server.appendRoute("GET /static/*") { request in
            // `code serve-web` exposes a few bundle-root files under
            // /static/resources/server/ (icons, manifest).
            var path = String(request.path.dropFirst("/static/".count))
            if path.hasPrefix("resources/server/") {
                path = String(path.dropFirst("resources/server/".count))
            }
            return Self.fileResponse(webRoot.appendingPathComponent(path))
        }
        await server.appendRoute("GET /ipad-files/*") { request in
            let path = String(request.path.dropFirst("/ipad-files/".count))
            return Self.fileResponse(extensionRoot.appendingPathComponent(path))
        }
    }

    // MARK: - Workbench page

    private func workbenchResponse() -> HTTPResponse {
        guard let templateURL = Bundle.main.url(forResource: "workbench", withExtension: "html"),
              let template = try? String(contentsOf: templateURL, encoding: .utf8) else {
            return HTTPResponse(statusCode: .notFound)
        }

        var configuration: [String: Any] = [
            "productConfiguration": [
                "nameShort": "Code (iPad)",
                "nameLong": "Code on iPad",
                "applicationName": "code-ipad",
                "embedderIdentifier": "ios-wrapper",
                "extensionsGallery": Self.extensionsGallery,
                // Null out the compiled-in vscode-cdn.net templates so the
                // extension host iframe and webviews stay on OUR origin: the
                // ipad-files bridge is BroadcastChannel-based (same-origin
                // only), and same-origin webviews work offline.
                "webEndpointUrlTemplate": NSNull(),
                "webviewContentExternalBaseUrlTemplate": NSNull(),
            ],
            "additionalBuiltinExtensions": [
                ["scheme": "http", "authority": "localhost:\(Self.port)", "path": "/ipad-files"],
            ],
            // Nulling webviewContentExternalBaseUrlTemplate is NOT enough: the
            // environment service re-defaults to vscode-cdn.net (a cross-origin
            // iframe whose third-party service worker WebKit blocks → blank
            // webviews). This option takes precedence over both. Same-origin
            // webviews trade isolation for working offline — fine single-user.
            "webviewEndpoint": "http://localhost:\(Self.port)/static/out/vs/workbench/contrib/webview/browser/pre/",
            "callbackRoute": "/callback",
        ]
        if let remote {
            configuration["remoteAuthority"] = remote.authority
            configuration["connectionToken"] = remote.connectionToken
        }

        let values: [String: String] = [
            "WORKBENCH_WEB_CONFIGURATION": Self.asAttributeJSON(configuration),
            "WORKBENCH_AUTH_SESSION": "",
            "WORKBENCH_WEB_BASE_URL": "/static",
            "WORKBENCH_NLS_URL": "", // empty -> fallback applies (same as serve-web)
            "WORKBENCH_NLS_FALLBACK_URL": "/static/out/nls.messages.js",
        ]

        var html = template
        for (key, value) in values {
            html = html.replacingOccurrences(of: "{{\(key)}}", with: value)
        }

        var response = HTTPResponse(
            statusCode: .ok,
            body: html.data(using: .utf8) ?? Data()
        )
        response.headers[HTTPHeader("Content-Type")] = "text/html; charset=utf-8"
        response.headers[HTTPHeader("Access-Control-Allow-Origin")] = "*"
        return response
    }

    /// JSON for embedding in an HTML attribute (quotes become &quot;), exactly
    /// like serve-web's asJSON().
    private static func asAttributeJSON(_ value: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return "" }
        return json.replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: - Static files

    private static func fileResponse(_ url: URL) -> HTTPResponse {
        let standardized = url.standardizedFileURL
        guard let data = try? Data(contentsOf: standardized) else {
            return HTTPResponse(statusCode: .notFound)
        }
        var response = HTTPResponse(statusCode: .ok, body: data)
        response.headers[HTTPHeader("Content-Type")] = mimeType(for: standardized.pathExtension)
        // Loopback host aliases (localhost vs 127.0.0.1) are distinct origins;
        // keep cross-origin fetches (e.g. the builtin extension) working.
        response.headers[HTTPHeader("Access-Control-Allow-Origin")] = "*"
        return response
    }

    private static func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "html": return "text/html; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json": return "application/json; charset=utf-8"
        case "wasm": return "application/wasm"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "ico": return "image/x-icon"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        case "ttf": return "font/ttf"
        case "mp3": return "audio/mpeg"
        case "map", "txt", "md": return "text/plain; charset=utf-8"
        case "tmgrammar", "tmlanguage", "tmtheme", "plist": return "text/plain; charset=utf-8"
        default: return "application/octet-stream"
        }
    }
}
