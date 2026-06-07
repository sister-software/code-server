import UIKit
import UniformTypeIdentifiers

enum FileBridgeError: Error {
    case unknownRoot
    case notFound
    case cancelled
    case noPresenter
    case io(String)
}

/// Backs the native side of local-file support: the user picks folders with the
/// document picker, we persist security-scoped bookmarks to them, and expose
/// FileManager operations keyed by a stable root id. The web extension reaches
/// these through `FileBridgeSchemeHandler`.
final class LocalFileStore: NSObject {
    static let shared = LocalFileStore()

    /// View controller used to present the document picker.
    weak var presenter: UIViewController?

    private let defaults = UserDefaults.standard
    private let bookmarksKey = "localFolderBookmarks" // [id: base64 bookmark data]
    private let namesKey = "localFolderNames"          // [id: display name]

    private var pickCompletion: ((Result<(id: String, name: String), Error>) -> Void)?

    // MARK: - Roots

    func roots() -> [(id: String, name: String)] {
        let names = storedNames()
        return storedBookmarks().keys.map { ($0, names[$0] ?? $0) }
    }

    func pickFolder(completion: @escaping (Result<(id: String, name: String), Error>) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard let presenter = self.presenter else {
                completion(.failure(FileBridgeError.noPresenter))
                return
            }
            self.pickCompletion = completion
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
            picker.delegate = self
            picker.allowsMultipleSelection = false
            presenter.present(picker, animated: true)
        }
    }

    // MARK: - File operations (run off the main thread)

    func stat(rootId: String, path: String) throws -> [String: Any] {
        try withScopedURL(rootId: rootId, path: path) { url in
            let fm = FileManager.default
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { throw FileBridgeError.notFound }
            let attrs = try fm.attributesOfItem(atPath: url.path)
            let size = (attrs[.size] as? Int) ?? 0
            let mtime = Int(((attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0) * 1000)
            let ctime = Int(((attrs[.creationDate] as? Date)?.timeIntervalSince1970 ?? 0) * 1000)
            return ["type": isDir.boolValue ? "directory" : "file", "size": size, "mtime": mtime, "ctime": ctime]
        }
    }

    func list(rootId: String, path: String) throws -> [[String: Any]] {
        try withScopedURL(rootId: rootId, path: path) { url in
            let items = try FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
            )
            return try items.map { child in
                let isDir = try child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory ?? false
                return ["name": child.lastPathComponent, "type": isDir ? "directory" : "file"]
            }
        }
    }

    func read(rootId: String, path: String) throws -> Data {
        try withScopedURL(rootId: rootId, path: path) { try Data(contentsOf: $0) }
    }

    func write(rootId: String, path: String, data: Data) throws {
        try withScopedURL(rootId: rootId, path: path) { try data.write(to: $0, options: .atomic) }
    }

    func makeDirectory(rootId: String, path: String) throws {
        try withScopedURL(rootId: rootId, path: path) {
            try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true)
        }
    }

    func delete(rootId: String, path: String) throws {
        try withScopedURL(rootId: rootId, path: path) { try FileManager.default.removeItem(at: $0) }
    }

    func rename(rootId: String, from: String, to: String) throws {
        guard let root = resolveRoot(rootId) else { throw FileBridgeError.unknownRoot }
        let accessed = root.startAccessingSecurityScopedResource()
        defer { if accessed { root.stopAccessingSecurityScopedResource() } }
        try FileManager.default.moveItem(at: resolved(root, from), to: resolved(root, to))
    }

    // MARK: - Bookmarks

    private func storedBookmarks() -> [String: String] {
        defaults.dictionary(forKey: bookmarksKey) as? [String: String] ?? [:]
    }

    private func storedNames() -> [String: String] {
        defaults.dictionary(forKey: namesKey) as? [String: String] ?? [:]
    }

    private func store(id: String, bookmark: Data, name: String) {
        var bookmarks = storedBookmarks()
        bookmarks[id] = bookmark.base64EncodedString()
        defaults.set(bookmarks, forKey: bookmarksKey)
        var names = storedNames()
        names[id] = name
        defaults.set(names, forKey: namesKey)
    }

    private func resolveRoot(_ id: String) -> URL? {
        guard let base64 = storedBookmarks()[id], let data = Data(base64Encoded: base64) else { return nil }
        var stale = false
        return try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
    }

    private func resolved(_ root: URL, _ relativePath: String) -> URL {
        relativePath.isEmpty ? root : root.appendingPathComponent(relativePath)
    }

    private func withScopedURL<T>(rootId: String, path: String, _ body: (URL) throws -> T) throws -> T {
        guard let root = resolveRoot(rootId) else { throw FileBridgeError.unknownRoot }
        let accessed = root.startAccessingSecurityScopedResource()
        defer { if accessed { root.stopAccessingSecurityScopedResource() } }
        return try body(resolved(root, path))
    }
}

extension LocalFileStore: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else {
            finishPick(.failure(FileBridgeError.cancelled))
            return
        }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            let bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            let id = UUID().uuidString
            let name = url.lastPathComponent
            store(id: id, bookmark: bookmark, name: name)
            finishPick(.success((id, name)))
        } catch {
            finishPick(.failure(error))
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        finishPick(.failure(FileBridgeError.cancelled))
    }

    private func finishPick(_ result: Result<(id: String, name: String), Error>) {
        let completion = pickCompletion
        pickCompletion = nil
        completion?(result)
    }
}
