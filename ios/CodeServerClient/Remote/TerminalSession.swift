import Foundation

/// Pseudo-terminal backed by `ios_system` (a-Shell's engine).
///
/// A dedicated pthread owns the session. Command lines are delivered out-of-band
/// (the front-end does prompt editing and ships a whole line via `runCommand`);
/// the stdin PIPE is reserved for the *running* command's raw input, so
/// interactive programs (REPLs, editors) get character-at-a-time keystrokes and
/// a tty (`ios_settty`). Output streams back over the stdout pipe.
final class TerminalSession {

    let id: Int
    private var cols: Int
    private var rows: Int

    /// ios_system identifies sessions by a C STRING (it strcmp's them), not an
    /// arbitrary pointer — pass a stable, owned string. Freed in deinit.
    private let sidString: UnsafeMutablePointer<CChar>
    private var sessionId: UnsafeRawPointer { UnsafeRawPointer(sidString) }

    var onData: ((String) -> Void)?
    var onExit: ((Int32) -> Void)?
    /// Fires when a command finishes (and once at startup) so the front-end can
    /// return to prompt mode. Main queue.
    var onReady: (() -> Void)?

    private var stdinPipe: [Int32] = [-1, -1]   // [0]=read(command), [1]=write(us)
    private var stdoutPipe: [Int32] = [-1, -1]  // [0]=read(us),       [1]=write(command)

    private var thread: pthread_t?
    private var stdoutSource: DispatchSourceRead?
    private let queue = DispatchQueue(label: "codeserver.terminal")

    // Command delivery to the session thread.
    private let commandSemaphore = DispatchSemaphore(value: 0)
    private let commandLock = NSLock()
    private var pendingCommands: [String] = []
    private var closed = false
    private var commandRunning = false

    init(id: Int, cols: Int, rows: Int) {
        self.id = id
        self.cols = cols
        self.rows = rows
        self.sidString = strdup("ipad-term-\(id)")
        setenv("COLUMNS", "\(cols)", 1)
        setenv("LINES", "\(rows)", 1)
        setenv("TERM", "xterm-256color", 1)
    }

    deinit {
        forceKill()
        free(sidString)
    }

    // MARK: - start

    func start() -> Bool {
        guard pipe(&stdinPipe) == 0, pipe(&stdoutPipe) == 0 else { return false }

        let raw = UnsafeMutablePointer<TerminalSession>.allocate(capacity: 1)
        raw.initialize(to: self)

        // ios_system commands can use deep stacks; give the thread room.
        var attr = pthread_attr_t()
        pthread_attr_init(&attr)
        pthread_attr_setstacksize(&attr, 4 * 1024 * 1024)

        let rc = pthread_create(&thread, &attr, { ptr in
            let session = ptr.assumingMemoryBound(to: TerminalSession.self).pointee

            let sid = session.sessionId
            let inFile = fdopen(session.stdinPipe[0], "r")     // command reads
            let outFile = fdopen(session.stdoutPipe[1], "w")   // command writes
            setvbuf(inFile, nil, _IONBF, 0)
            setvbuf(outFile, nil, _IONBF, 0)

            thread_stdin = inFile
            thread_stdout = outFile
            thread_stderr = outFile

            let configure = {
                ios_switchSession(sid)
                ios_setContext(sid)
                ios_setStreams(inFile, outFile, outFile)
                ios_settty(inFile)
                ios_setWindowSize(Int32(session.cols), Int32(session.rows), sid)
            }
            configure()

            DispatchQueue.main.async { session.onReady?() } // initial prompt

            while true {
                session.commandSemaphore.wait()
                session.commandLock.lock()
                if session.closed { session.commandLock.unlock(); break }
                let cmd = session.pendingCommands.isEmpty ? nil : session.pendingCommands.removeFirst()
                if cmd != nil { session.commandRunning = true }
                session.commandLock.unlock()

                guard let command = cmd else { continue }
                if !command.isEmpty {
                    configure() // re-assert: another terminal may have switched global state
                    ios_system(command)
                    fflush(outFile)
                }
                session.commandLock.lock()
                session.commandRunning = false
                session.commandLock.unlock()
                DispatchQueue.main.async { session.onReady?() }
            }

            ios_closeSession(sid)
            fflush(outFile)
            fclose(inFile)
            fclose(outFile)
            DispatchQueue.main.async { session.onExit?(0) }
            ptr.deallocate()
            return nil
        }, raw)
        pthread_attr_destroy(&attr)

        if rc != 0 { raw.deallocate(); return false }

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
        src.setCancelHandler { [weak self] in self?.stdoutPipe[0] = -1 }
        src.resume()
        stdoutSource = src
        return true
    }

    // MARK: - input

    /// Run a command line (from the front-end's prompt editor).
    func runCommand(_ line: String) {
        commandLock.lock()
        pendingCommands.append(line)
        commandLock.unlock()
        commandSemaphore.signal()
    }

    /// Raw keystrokes for the currently running command's stdin.
    func writeInput(_ data: String) {
        guard stdinPipe[1] >= 0, let d = data.data(using: .utf8) else { return }
        d.withUnsafeBytes { _ = Darwin.write(stdinPipe[1], $0.baseAddress, d.count) }
    }

    /// Ctrl-C: interrupt the running command (no-op at the prompt).
    func interrupt() {
        commandLock.lock(); let running = commandRunning; commandLock.unlock()
        if running { ios_kill() }
    }

    // MARK: - resize

    func resize(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = rows
        setenv("COLUMNS", "\(cols)", 1)
        setenv("LINES", "\(rows)", 1)
        ios_setWindowSize(Int32(cols), Int32(rows), sessionId)
    }

    // MARK: - shutdown

    func requestExit() { forceKill() }

    func forceKill() {
        commandLock.lock()
        if closed { commandLock.unlock(); return }
        closed = true
        let running = commandRunning
        commandLock.unlock()
        commandSemaphore.signal() // unblock the wait if idle
        if running { ios_kill() }  // unblock a running command

        stdoutSource?.cancel()
        stdoutSource = nil
        thread = nil
        if stdinPipe[1] >= 0 { Darwin.close(stdinPipe[1]); stdinPipe[1] = -1 }
        if stdoutPipe[0] >= 0 { Darwin.close(stdoutPipe[0]); stdoutPipe[0] = -1 }
        if stdoutPipe[1] >= 0 { Darwin.close(stdoutPipe[1]); stdoutPipe[1] = -1 }
    }
}
