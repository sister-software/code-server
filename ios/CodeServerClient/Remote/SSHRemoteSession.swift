import Foundation
import NIOCore
import NIOPosix
import NIOSSH

/// Native reimplementation of what the Remote-SSH extension does on desktop —
/// which can't run here (it's a Node extension; web workbenches have no local
/// extension host). The app takes its place:
///
///   1. SSH to the host (password auth for v1).
///   2. Run a bootstrap that downloads the OFFICIAL vscode-server at the exact
///      commit of our bundled web workbench (the remote protocol requires
///      matching commits) and starts it on a loopback port with a fresh
///      connection token. The exec channel stays open: the server lives and
///      dies with this session.
///   3. Listen on iPad loopback and forward each connection over an SSH
///      direct-tcpip channel to the server.
///
/// The workbench then gets `remoteAuthority: "localhost:<localPort>"` plus the
/// token, and runs a genuine remote session — server-side extension host,
/// terminals, the lot — with parity to code-server.
final class SSHRemoteSession {
    struct Config {
        var host: String
        var port: Int = 22
        var username: String
        var password: String
    }

    struct Ready {
        let localPort: Int
        let connectionToken: String
    }

    enum SSHError: LocalizedError {
        case serverDidNotStart(String)
        case channelSetupFailed
        case authenticationFailed(String)

        var errorDescription: String? {
            switch self {
            case .serverDidNotStart(let log):
                return "vscode-server did not start.\n\(log.suffix(800))"
            case .channelSetupFailed:
                return "SSH channel setup failed"
            case .authenticationFailed(let detail):
                return "SSH authentication failed — check the password, and that the server allows password auth (sshd PasswordAuthentication yes).\n\(detail)"
            }
        }
    }

    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private var sshChannel: Channel?
    private var listenerChannel: Channel?

    deinit { stop() }

    func stop() {
        try? listenerChannel?.close().wait()
        try? sshChannel?.close().wait()
        listenerChannel = nil
        sshChannel = nil
    }

    func start(config: Config, vscodeCommit: String, progress: @escaping (String) -> Void) async throws -> Ready {
        progress("Connecting to \(config.host):\(config.port)…")
        let authPromise = group.next().makePromise(of: Void.self)
        let ssh: Channel
        do {
            ssh = try await connect(config: config, authPromise: authPromise)
        } catch {
            authPromise.fail(error) // never leak the promise (NIO asserts on deinit)
            throw error
        }
        sshChannel = ssh

        progress("TCP connected — authenticating…")
        try await authPromise.futureResult.get()
        progress("SSH authenticated — starting vscode-server…")

        let token = UUID().uuidString
        let remotePort = try await bootstrapServer(ssh: ssh, commit: vscodeCommit, token: token, progress: progress)

        progress("Opening tunnel…")
        let localPort = try await startForwarder(ssh: ssh, remotePort: remotePort)
        return Ready(localPort: localPort, connectionToken: token)
    }

    // MARK: - Connection

    private func connect(config: Config, authPromise: EventLoopPromise<Void>) async throws -> Channel {
        let clientConfig = SSHClientConfiguration(
            userAuthDelegate: PasswordAuthDelegate(username: config.username, password: config.password),
            serverAuthDelegate: AcceptAllHostKeysDelegate()
        )
        return try await ClientBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel in
                channel.pipeline.addHandlers([
                    NIOSSHHandler(role: .client(clientConfig), allocator: channel.allocator, inboundChildChannelInitializer: nil),
                    AuthStateHandler(authPromise: authPromise),
                ])
            }
            .connect(host: config.host, port: config.port)
            .get()
    }

    // MARK: - Server bootstrap (long-running exec)

    private func bootstrapServer(
        ssh: Channel,
        commit: String,
        token: String,
        progress: @escaping (String) -> Void
    ) async throws -> Int {
        let script = Self.bootstrapScript(commit: commit, token: token)
        let portPromise = ssh.eventLoop.makePromise(of: Int.self)

        let childPromise = ssh.eventLoop.makePromise(of: Channel.self)
        ssh.pipeline.handler(type: NIOSSHHandler.self).whenSuccess { handler in
            handler.createChannel(childPromise, channelType: .session) { child, _ in
                child.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).flatMap {
                    child.pipeline.addHandlers([
                        ExecHandler(command: script, portPromise: portPromise, progress: progress),
                    ])
                }
            }
        }
        _ = try await childPromise.futureResult.get()
        return try await portPromise.futureResult.get()
    }

    private static func bootstrapScript(commit: String, token: String) -> String {
        // Single sh -c payload. The official server tarball is keyed by the web
        // bundle's commit; EXTENSIONS_GALLERY mirrors the user's code-server
        // setup so server-side extension installs use the official marketplace.
        """
        set -e
        COMMIT=\(commit)
        DIR="$HOME/.ipad-vscode-server/$COMMIT"
        if [ ! -x "$DIR/bin/code-server" ]; then
          echo "ios-bootstrap: downloading vscode-server $COMMIT"
          mkdir -p "$DIR"
          case "$(uname -m)" in aarch64|arm64) ARCH=arm64 ;; *) ARCH=x64 ;; esac
          curl -fsSL "https://update.code.visualstudio.com/commit:$COMMIT/server-linux-$ARCH/stable" -o "$DIR/server.tgz"
          tar -xzf "$DIR/server.tgz" -C "$DIR" --strip-components=1
          rm -f "$DIR/server.tgz"
        fi
        export EXTENSIONS_GALLERY='{"serviceUrl":"https://marketplace.visualstudio.com/_apis/public/gallery","itemUrl":"https://marketplace.visualstudio.com/items"}'
        exec "$DIR/bin/code-server" --host 127.0.0.1 --port 0 --connection-token "\(token)" --accept-server-license-terms --telemetry-level off
        """
    }

    // MARK: - Local forwarder (loopback TCP -> SSH direct-tcpip)

    private func startForwarder(ssh: Channel, remotePort: Int) async throws -> Int {
        let sshHandler = try await ssh.pipeline.handler(type: NIOSSHHandler.self).get()

        let listener = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { local in
                let (localGlue, sshGlue) = GlueHandler.matchedPair()
                return local.pipeline.addHandler(localGlue).flatMap {
                    let childPromise = local.eventLoop.makePromise(of: Channel.self)
                    sshHandler.createChannel(
                        childPromise,
                        channelType: .directTCPIP(.init(
                            targetHost: "127.0.0.1",
                            targetPort: remotePort,
                            originatorAddress: try! SocketAddress(ipAddress: "127.0.0.1", port: 0)
                        ))
                    ) { child, _ in
                        child.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).flatMap {
                            child.pipeline.addHandlers([SSHChannelDataTranscoder(), sshGlue])
                        }
                    }
                    // If the SSH side fails, drop the local connection too.
                    childPromise.futureResult.whenFailure { _ in local.close(promise: nil) }
                    return local.eventLoop.makeSucceededVoidFuture()
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()

        listenerChannel = listener
        guard let port = listener.localAddress?.port else { throw SSHError.channelSetupFailed }
        return port
    }
}

// MARK: - Handshake/auth observation

/// The TCP connect resolving says nothing about SSH itself — the handshake and
/// user auth run afterwards. This handler turns their outcome into a promise so
/// failures (wrong password, key-only sshd) surface instead of hanging.
private final class AuthStateHandler: ChannelInboundHandler {
    typealias InboundIn = Any

    private let authPromise: EventLoopPromise<Void>
    private var completed = false

    init(authPromise: EventLoopPromise<Void>) {
        self.authPromise = authPromise
    }

    func handlerAdded(context: ChannelHandlerContext) {
        context.eventLoop.scheduleTask(in: .seconds(30)) { [weak self] in
            self?.complete(.failure(SSHRemoteSession.SSHError.authenticationFailed("timed out during SSH handshake/auth")))
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is UserAuthSuccessEvent {
            complete(.success(()))
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        complete(.failure(SSHRemoteSession.SSHError.authenticationFailed(String(describing: error))))
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        complete(.failure(SSHRemoteSession.SSHError.authenticationFailed("connection closed by server during handshake")))
        context.fireChannelInactive()
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        // A channel that never went active skips channelInactive; this is the
        // last guaranteed callback. An uncompleted promise crashes on deinit.
        complete(.failure(SSHRemoteSession.SSHError.authenticationFailed("connection failed before SSH handshake")))
    }

    private func complete(_ result: Result<Void, Error>) {
        guard !completed else { return }
        completed = true
        authPromise.completeWith(result)
    }
}

// MARK: - Auth delegates

private final class PasswordAuthDelegate: NIOSSHClientUserAuthenticationDelegate {
    private let username: String
    private let password: String
    private var attempted = false

    init(username: String, password: String) {
        self.username = username
        self.password = password
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        guard availableMethods.contains(.password), !attempted else {
            nextChallengePromise.succeed(nil) // no more offers -> auth failure
            return
        }
        attempted = true
        nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(
            username: username,
            serviceName: "",
            offer: .password(.init(password: password))
        ))
    }
}

/// v1 trusts any host key (personal lab over Tailscale). TODO: trust-on-first-
/// use with a stored fingerprint before this touches anything less private.
private final class AcceptAllHostKeysDelegate: NIOSSHClientServerAuthenticationDelegate {
    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        validationCompletePromise.succeed(())
    }
}

// MARK: - Exec handler (runs the bootstrap, parses the server port)

private final class ExecHandler: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData

    private let command: String
    private let portPromise: EventLoopPromise<Int>
    private let progress: (String) -> Void
    private var buffer = ""
    private var log = ""
    private var execSent = false
    private var portCompleted = false

    init(command: String, portPromise: EventLoopPromise<Int>, progress: @escaping (String) -> Void) {
        self.command = command
        self.portPromise = portPromise
        self.progress = progress
    }

    // The SSH child channel can already be active by the time this handler
    // joins the pipeline (createChannel initializer ordering), in which case
    // channelActive never fires — send the exec from whichever happens.
    func handlerAdded(context: ChannelHandlerContext) {
        if context.channel.isActive {
            sendExec(context: context)
        }
        // Surface the log instead of hanging forever if the server never
        // announces its port (slow network is fine: first download can take a
        // few minutes; anything past that is a failure worth showing).
        context.eventLoop.scheduleTask(in: .seconds(300)) { [weak self] in
            guard let self, !self.portCompleted else { return }
            self.completePort(.failure(SSHRemoteSession.SSHError.serverDidNotStart("timed out\n" + self.log)))
        }
    }

    func channelActive(context: ChannelHandlerContext) {
        sendExec(context: context)
        context.fireChannelActive()
    }

    private func sendExec(context: ChannelHandlerContext) {
        guard !execSent else { return }
        execSent = true
        let exec = SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true)
        context.triggerUserOutboundEvent(exec, promise: nil)
    }

    private func completePort(_ result: Result<Int, Error>) {
        guard !portCompleted else { return }
        portCompleted = true
        portPromise.completeWith(result)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)
        guard case .byteBuffer(var bytes) = channelData.data,
              let text = bytes.readString(length: bytes.readableBytes) else { return }
        log += text
        buffer += text
        while let newline = buffer.firstIndex(of: "\n") {
            let line = String(buffer[..<newline])
            buffer = String(buffer[buffer.index(after: newline)...])
            handle(line: line)
        }
    }

    private func handle(line: String) {
        // Official server prints: "Extension host agent listening on <port>"
        if line.contains("listening on"),
           let port = line.split(separator: " ").compactMap({ Int($0.trimmingCharacters(in: .punctuationCharacters)) }).last {
            completePort(.success(port))
        } else if line.contains("ios-bootstrap:") {
            progress(line.replacingOccurrences(of: "ios-bootstrap: ", with: ""))
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        // Server exited (or never started): fail the port promise if pending.
        completePort(.failure(SSHRemoteSession.SSHError.serverDidNotStart(log)))
        context.fireChannelInactive()
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        // Last guaranteed callback (never-active channels skip channelInactive);
        // an uncompleted promise crashes on deinit.
        completePort(.failure(SSHRemoteSession.SSHError.serverDidNotStart(log.isEmpty ? "exec channel closed before any output" : log)))
    }
}

// MARK: - direct-tcpip plumbing

/// Translates between raw ByteBuffers (local TCP side) and SSHChannelData.
private final class SSHChannelDataTranscoder: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)
        guard case .byteBuffer(let bytes) = channelData.data else { return }
        context.fireChannelRead(wrapInboundOut(bytes))
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let bytes = unwrapOutboundIn(data)
        context.write(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(bytes))), promise: promise)
    }
}

/// Pipes two channels into each other (local socket <-> SSH child channel).
/// Simplified from swift-nio-ssh's example client; no explicit backpressure,
/// which is acceptable for an interactive editor protocol.
private final class GlueHandler: ChannelDuplexHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private var partner: GlueHandler?
    private var context: ChannelHandlerContext?

    static func matchedPair() -> (GlueHandler, GlueHandler) {
        let first = GlueHandler()
        let second = GlueHandler()
        first.partner = second
        second.partner = first
        return (first, second)
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
        partner = nil
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let bytes = unwrapInboundIn(data)
        partner?.write(bytes)
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        partner?.flush()
    }

    func channelInactive(context: ChannelHandlerContext) {
        partner?.close()
        context.fireChannelInactive()
    }

    private func write(_ bytes: ByteBuffer) {
        context?.write(NIOAny(bytes), promise: nil)
    }

    private func flush() {
        context?.flush()
    }

    private func close() {
        context?.close(promise: nil)
    }
}
