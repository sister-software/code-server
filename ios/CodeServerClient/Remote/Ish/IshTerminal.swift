import Foundation

/// Drives the iSH x86-Linux emulator: boots an Alpine guest once and exposes a
/// single console wired to the terminal front-end. v1 is one shared console
/// (one VM, one shell); multiple panels would share it.
final class IshTerminal {
    static let shared = IshTerminal()

    /// Receives guest console output (already off the emulator thread it fires on).
    var onOutput: ((Data) -> Void)?

    private let bootQueue = DispatchQueue(label: "software.sister.ish.boot")
    private var booting = false

    var isRunning: Bool { ish_is_running() != 0 }

    /// Boot the guest if it isn't already. Idempotent.
    func ensureBooted() {
        bootQueue.async { [self] in
            guard ish_is_running() == 0, !booting else { return }
            booting = true
            let root = prepareWritableRootfs()
            let callback: @convention(c) (UnsafePointer<CChar>?, Int32) -> Void = { buf, len in
                guard let buf, len > 0 else { return }
                let data = Data(bytes: buf, count: Int(len))
                IshTerminal.shared.onOutput?(data)
            }
            _ = root.withCString { ish_boot($0, callback) }
            booting = false
        }
    }

    func sendInput(_ data: Data) {
        guard !data.isEmpty else { return }
        data.withUnsafeBytes { raw in
            ish_send_input(raw.bindMemory(to: CChar.self).baseAddress, Int32(data.count))
        }
    }

    func setWinsize(cols: Int, rows: Int) {
        ish_set_winsize(Int32(cols), Int32(rows))
    }

    /// The guest writes to its filesystem, so copy the bundled read-only fakefs
    /// to Application Support on first run and boot from there.
    private func prepareWritableRootfs() -> String {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dest = support.appendingPathComponent("ish-rootfs", isDirectory: true)
        if !fm.fileExists(atPath: dest.appendingPathComponent("meta.db").path) {
            try? fm.createDirectory(at: support, withIntermediateDirectories: true)
            try? fm.removeItem(at: dest)
            if let src = Bundle.main.resourceURL?.appendingPathComponent("ish-rootfs") {
                try? fm.copyItem(at: src, to: dest)
            }
        }
        return dest.path
    }
}
