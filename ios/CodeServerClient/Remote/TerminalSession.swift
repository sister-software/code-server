import Foundation

/// Pseudo-terminal backed by `ios_system`: a pthread that runs a readline
/// loop dispatching each line to `ios_system()`. Pipes bridge keyboard input
/// (from VS Code via WKWebView) and terminal output (back to VS Code).
///
/// ios_system uses per-thread `thread_stdin` / `thread_stdout` / `thread_stderr`
/// FILE* globals — we redirect those to our pipes before entering the loop.
final class TerminalSession {

    let id: Int
    private var cols: Int
    private var rows: Int

    /// ios_system identifies sessions by a C STRING (it strcmp's them), not an
    /// arbitrary pointer — pass a stable, owned string. Freed in deinit.
    private let sidString: UnsafeMutablePointer<CChar>
    private var sessionId: UnsafeRawPointer { UnsafeRawPointer(sidString) }

    /// Called with stdout + stderr output (UTF‑8 chunks).
    var onData: ((String) -> Void)?

    /// Called when the loop exits (either "exit" command or force‑kill).
    var onExit: ((Int32) -> Void)?

    /// Called when a command finishes (and once at startup) so the front-end
    /// can print its prompt. Fires on the main queue.
    var onReady: (() -> Void)?

    // -- pipe descriptors (owned by the reading end) --
    private var stdinPipe: [Int32] = [-1, -1]   // [0]=read(shell), [1]=write(us)
    private var stdoutPipe: [Int32] = [-1, -1]  // [0]=read(us),    [1]=write(shell)

    private var thread: pthread_t?
    private var stdoutSource: DispatchSourceRead?
    private let queue = DispatchQueue(label: "codeserver.terminal.\(UUID().uuidString.prefix(8))")

    // MARK: - init / deinit

    init(id: Int, cols: Int, rows: Int) {
        self.id = id
        self.cols = cols
        self.rows = rows
        self.sidString = strdup("ipad-term-\(id)")
        setenv("COLUMNS", "\(cols)", 1)
        setenv("LINES", "\(rows)", 1)
    }

    deinit {
        forceKill()
        free(sidString)
    }

    // MARK: - start

    /// Returns true if the shell thread launched successfully.
    func start() -> Bool {
        guard pipe(&stdinPipe) == 0, pipe(&stdoutPipe) == 0 else { return false }

        let raw = UnsafeMutablePointer<TerminalSession>.allocate(capacity: 1)
        raw.initialize(to: self)

        let rc = pthread_create(&thread, nil, { ptr in
            let session = ptr.assumingMemoryBound(to: TerminalSession.self).pointee

            let sid = session.sessionId
            let inFile = fdopen(session.stdinPipe[0], "r")     // shell reads
            let outFile = fdopen(session.stdoutPipe[1], "w")   // shell writes
            setvbuf(outFile, nil, _IONBF, 0)                   // unbuffered → output reaches the pipe promptly

            thread_stdin = inFile
            thread_stdout = outFile
            thread_stderr = outFile

            // Register the session once so chdir/env persist across commands.
            ios_switchSession(sid)
            ios_setContext(sid)
            ios_setStreams(inFile, outFile, outFile)
            ios_setWindowSize(Int32(session.cols), Int32(session.rows), sid)

            // Initial prompt.
            DispatchQueue.main.async { session.onReady?() }

            // Shell readline loop — one line → one ios_system() call.
            var lineBuf = [CChar](repeating: 0, count: 4096)
            while fgets(&lineBuf, Int32(lineBuf.count), inFile) != nil {
                let line = String(cString: lineBuf).trimmingCharacters(in: .newlines)
                if line == "exit" { break }
                if !line.isEmpty {
                    // Re-assert this session's streams before each command in
                    // case another terminal switched the global ios_system state.
                    ios_switchSession(sid)
                    ios_setContext(sid)
                    ios_setStreams(inFile, outFile, outFile)
                    ios_setWindowSize(Int32(session.cols), Int32(session.rows), sid)
                    ios_system(line)
                    fflush(outFile)
                }
                DispatchQueue.main.async { session.onReady?() }
                lineBuf = [CChar](repeating: 0, count: 4096)
            }

            ios_closeSession(sid)
            fflush(outFile)
            fclose(inFile)
            fclose(outFile)

            DispatchQueue.main.async { session.onExit?(0) }
            ptr.deallocate()
            return nil
        }, raw)

        if rc != 0 { raw.deallocate(); return false }

        // Dispatch source for stdout reads.
        let src = DispatchSource.makeReadSource(fileDescriptor: stdoutPipe[0], queue: queue)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            let n = src.data
            if n > 0 {
                var buf = [UInt8](repeating: 0, count: Int(n))
                let r = read(self.stdoutPipe[0], &buf, buf.count)
                if r > 0, let s = String(bytes: buf[0..<r], encoding: .utf8) {
                    DispatchQueue.main.async { self.onData?(s) }
                }
            }
        }
        src.setCancelHandler { [weak self] in
            self?.stdoutPipe[0] = -1
        }
        src.resume()
        stdoutSource = src

        return true
    }

    // MARK: - write (stdin)

    func writeInput(_ data: String) {
        guard stdinPipe[1] >= 0, let d = data.data(using: .utf8) else { return }
        d.withUnsafeBytes { _ = Darwin.write(stdinPipe[1], $0.baseAddress, d.count) }
    }

    func writeln(_ line: String) { writeInput(line + "\n") }

    // MARK: - resize

    func resize(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = rows
        setenv("COLUMNS", "\(cols)", 1)
        setenv("LINES", "\(rows)", 1)
        ios_setWindowSize(Int32(cols), Int32(rows), sessionId)
    }

    // MARK: - shutdown

    /// Graceful: sends "exit\n".
    func requestExit() {
        writeln("exit")
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(3)) { [weak self] in
            self?.forceKill()
        }
    }

    /// Immediate: cancels thread and closes pipes.
    func forceKill() {
        stdoutSource?.cancel()
        stdoutSource = nil
        if let t = thread { pthread_cancel(t); thread = nil }
        if stdinPipe[1]  >= 0 { Darwin.close(stdinPipe[1]);  stdinPipe[1]  = -1 }
        if stdoutPipe[0] >= 0 { Darwin.close(stdoutPipe[0]); stdoutPipe[0] = -1 }
        if stdoutPipe[1] >= 0 { Darwin.close(stdoutPipe[1]); stdoutPipe[1] = -1 }
        onExit?(137)
    }
}
