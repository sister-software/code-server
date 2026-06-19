import Foundation

/// Drives the iSH x86-Linux emulator: one Alpine guest, many terminals (the
/// console for pid 1, pseudo-terminals after). Each VS Code terminal maps to a
/// numeric id; output is routed back to the matching sink.
final class IshTerminal {
    static let shared = IshTerminal()

    /// Per-id output sink. nil data signals the shell exited.
    private var sinks: [Int32: (Data?) -> Void] = [:]
    private let lock = NSLock()

    /// Boot/spawn must be serialized: iSH's `current` is thread-local and
    /// become_new_init_child/do_execve mutate it.
    private let queue = DispatchQueue(label: "software.sister.ish")

    private init() {
        ish_set_output { id, buf, len in
            let data: Data? = (buf != nil && len > 0) ? Data(bytes: buf!, count: Int(len)) : nil
            IshTerminal.shared.emit(id: id, data: data)
        }
    }

    private func emit(id: Int32, data: Data?) {
        lock.lock(); let sink = sinks[id]; lock.unlock()
        sink?(data)
    }

    func open(id: Int, cols: Int, rows: Int, onOutput: @escaping (Data?) -> Void) {
        lock.lock(); sinks[Int32(id)] = onOutput; lock.unlock()
        queue.async {
            let root = self.prepareWritableRootfs()
            _ = root.withCString { ish_open_terminal(Int32(id), Int32(cols), Int32(rows), $0) }
        }
    }

    func input(id: Int, _ data: Data) {
        guard !data.isEmpty else { return }
        data.withUnsafeBytes { raw in
            ish_send_input(Int32(id), raw.bindMemory(to: CChar.self).baseAddress, Int32(data.count))
        }
    }

    func resize(id: Int, cols: Int, rows: Int) {
        ish_set_winsize(Int32(id), Int32(cols), Int32(rows))
    }

    func close(id: Int) {
        ish_close_terminal(Int32(id))
        lock.lock(); sinks[Int32(id)] = nil; lock.unlock()
    }

    /// Run guest-fs work on the same serial queue as boot/spawn (iSH's `current`
    /// is thread-local; fs ops set it to pid 1 and must not race the kernel).
    func onFSQueue(_ work: @escaping () -> Void) {
        queue.async(execute: work)
    }

    /// The guest writes to its filesystem, so copy the bundled read-only fakefs
    /// to Application Support on first run and boot from there.
    private func prepareWritableRootfs() -> String {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        // Versioned: bumping forces a fresh copy when the bundled rootfs changes
        // (e.g. i386 → arm64, rcarmo → OpenMinis, or new baked defaults), instead
        // of reusing a stale writable copy.
        let version = "ish-rootfs-operator5"
        let dest = support.appendingPathComponent(version, isDirectory: true)
        if !fm.fileExists(atPath: dest.appendingPathComponent("meta.db").path) {
            try? fm.createDirectory(at: support, withIntermediateDirectories: true)
            // Drop any prior versioned copies so old rootfs revisions don't
            // accumulate (each is tens of MB) when the version is bumped.
            for name in (try? fm.contentsOfDirectory(atPath: support.path)) ?? []
            where name.hasPrefix("ish-rootfs-") {
                try? fm.removeItem(at: support.appendingPathComponent(name))
            }
            if let src = Bundle.main.resourceURL?.appendingPathComponent("ish-rootfs") {
                try? fm.copyItem(at: src, to: dest)
            }
        }
        return dest.path
    }
}
