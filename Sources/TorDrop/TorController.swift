import Foundation
import Darwin

enum TorError: LocalizedError {
    case binaryNotFound
    case bootstrapTimeout
    case timeout(String)
    case controlConnectionFailed(String)
    case controlProtocolError(String)
    case processDied(Int32)

    var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            return "tor binary not found. Install it with `brew install tor`, or install Tor Browser in /Applications."
        case .bootstrapTimeout:
            return "Tor could not connect to the Tor network in time. Check your internet connection and try again."
        case .timeout(let what):
            return "Timed out waiting for tor: \(what)"
        case .controlConnectionFailed(let msg):
            return "Control connection failed: \(msg)"
        case .controlProtocolError(let msg):
            return "Tor control protocol error: \(msg)"
        case .processDied(let code):
            return "Tor process exited unexpectedly (code \(code))."
        }
    }
}

/// Manages a tor subprocess and an ephemeral v3 onion service created via the
/// control protocol (ADD_ONION NEW:ED25519-V3). Keys are never written to disk
/// (Flags=DiscardPK) and the service dies with the tor process.
///
/// All blocking control-port IO runs on a private serial queue. `stop()` may be
/// called from any thread at any time, including while `start` is in flight;
/// it wakes the IO queue, which then unwinds with `CancellationError`.
final class TorController {
    private let dataDirectory: URL
    private let controlPortFile: URL
    private let cookieFile: URL
    private let torrcFile: URL
    private let ioQueue = DispatchQueue(label: "tordrop.tor-control", qos: .userInitiated)

    private let stateLock = NSLock()
    private var cancelled = false
    private var controlSocket: Int32 = -1
    private var process: Process?

    // Touched only on ioQueue.
    private var parser = TorControlReplyParser()
    private var uploadedDescriptors: Set<String> = []

    private let logHandler: (String) -> Void
    private let progressHandler: (String, Double?) -> Void

    /// - Parameters:
    ///   - logHandler: receives tor's own log output and controller messages.
    ///   - progressHandler: receives a user-facing status line and, while
    ///     bootstrapping, a completion fraction in 0...1.
    init(logHandler: @escaping (String) -> Void,
         progressHandler: @escaping (String, Double?) -> Void = { _, _ in }) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("tordrop-\(UUID().uuidString)", isDirectory: true)
        self.dataDirectory = tmp
        self.controlPortFile = tmp.appendingPathComponent("control-port")
        self.cookieFile = tmp.appendingPathComponent("control_auth_cookie")
        self.torrcFile = tmp.appendingPathComponent("torrc")
        self.logHandler = logHandler
        self.progressHandler = progressHandler
    }

    deinit {
        if controlSocket >= 0 { Darwin.close(controlSocket) }
    }

    // MARK: Public API

    /// Starts tor, waits for bootstrap, and publishes a v3 hidden service
    /// forwarding onion port 80 → 127.0.0.1:<localPort>. Returns the `.onion`
    /// hostname (without scheme).
    func start(forwardingToLocalPort localPort: UInt16) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            ioQueue.async {
                do {
                    continuation.resume(returning: try self.startBlocking(localPort: localPort))
                } catch {
                    continuation.resume(throwing: self.isCancelled ? CancellationError() : error)
                }
            }
        }
    }

    /// Tears down the onion service and the tor process. Safe to call more
    /// than once and from any thread. With `waitUntilDone`, blocks until the
    /// process has exited and its data directory is gone (used at app quit).
    func stop(waitUntilDone: Bool = false) {
        stateLock.lock()
        cancelled = true
        // Wakes any blocked poll()/read() on the IO queue. The descriptor is
        // closed on the IO queue once nothing can be using it.
        if controlSocket >= 0 { Darwin.shutdown(controlSocket, SHUT_RDWR) }
        let process = self.process
        stateLock.unlock()

        if let process, process.isRunning { process.terminate() }

        let cleanup = { [self] in
            stateLock.lock()
            if controlSocket >= 0 {
                Darwin.close(controlSocket)
                controlSocket = -1
            }
            stateLock.unlock()

            if let process {
                let deadline = Date().addingTimeInterval(2)
                while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                (process.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
                (process.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
            }
            try? FileManager.default.removeItem(at: dataDirectory)
        }

        if waitUntilDone {
            ioQueue.sync(execute: cleanup)
        } else {
            ioQueue.async(execute: cleanup)
        }
    }

    // MARK: Start sequence (IO queue)

    private func startBlocking(localPort: UInt16) throws -> String {
        let binary = try Self.findTorBinary()
        log("Using tor at \(binary.path)")
        try checkCancelled()

        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        // An empty torrc keeps a user's system-wide tor configuration (e.g.
        // Homebrew's) from leaking into TorDrop's private instance.
        try Data().write(to: torrcFile)

        progressHandler("Starting Tor…", nil)
        try launchProcess(binary: binary)
        try waitForControlPortFile()
        guard let port = TorControlParsing.controlPort(
            inPortFile: (try? String(contentsOf: controlPortFile, encoding: .utf8)) ?? "") else {
            throw TorError.controlProtocolError("Cannot parse control port file")
        }
        log("Tor control port: \(port)")

        try connectAndAuthenticate(port: port)
        // Tor exits as soon as this control connection closes, so it can never
        // outlive TorDrop (even after a crash).
        try sendCommand("TAKEOWNERSHIP")
        try sendCommand("RESETCONF __OwningControllerProcess")

        try waitForBootstrap()
        log("Tor bootstrapped. Creating onion service…")
        progressHandler("Publishing onion service…", nil)

        try sendCommand("SETEVENTS HS_DESC")
        let reply = try sendCommand(
            "ADD_ONION NEW:ED25519-V3 Flags=DiscardPK Port=80,127.0.0.1:\(localPort)"
        )
        guard let serviceID = TorControlParsing.serviceID(in: reply) else {
            throw TorError.controlProtocolError("No ServiceID in ADD_ONION response:\n\(reply.text)")
        }
        log("Onion service created: \(serviceID).onion")

        try waitForDescriptorUpload(serviceID: serviceID, timeout: 90)
        _ = try? sendCommand("SETEVENTS")
        return "\(serviceID).onion"
    }

    private var isCancelled: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return cancelled
    }

    private func checkCancelled() throws {
        if isCancelled { throw CancellationError() }
    }

    // MARK: Binary discovery

    private static func findTorBinary() throws -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let torBrowserApps = ["/Applications/Tor Browser.app", "\(home)/Applications/Tor Browser.app"]
        let candidates = [
            "/opt/homebrew/bin/tor",
            "/usr/local/bin/tor",
            "/opt/local/bin/tor",
            "/usr/bin/tor"
        ] + torBrowserApps.flatMap { app in
            ["\(app)/Contents/MacOS/Tor/tor", "\(app)/Contents/MacOS/Tor/tor.real"]
        }
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }

        // Fall back to `which tor`. GUI apps inherit a minimal PATH, so add
        // the usual package-manager locations.
        let which = Process()
        which.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        which.arguments = ["tor"]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = ((env["PATH"].map { [$0] } ?? []) +
                       ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "\(home)/.nix-profile/bin"])
            .joined(separator: ":")
        which.environment = env
        let pipe = Pipe()
        which.standardOutput = pipe
        which.standardError = FileHandle.nullDevice
        if (try? which.run()) != nil {
            which.waitUntilExit()
            if which.terminationStatus == 0,
               let data = try? pipe.fileHandleForReading.readToEnd(),
               let path = String(data: data, encoding: .utf8)?
                   .trimmingCharacters(in: .whitespacesAndNewlines),
               !path.isEmpty,
               FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        throw TorError.binaryNotFound
    }

    // MARK: Process lifecycle

    private func launchProcess(binary: URL) throws {
        let p = Process()
        p.executableURL = binary
        p.arguments = [
            "-f", torrcFile.path,
            "--defaults-torrc", torrcFile.path,
            "--DataDirectory", dataDirectory.path,
            "--SOCKSPort", "0",
            "--ControlPort", "auto",
            "--ControlPortWriteToFile", controlPortFile.path,
            "--CookieAuthentication", "1",
            "--CookieAuthFile", cookieFile.path,
            "--Log", "notice stdout",
            "--ClientOnly", "1",
            "--AvoidDiskWrites", "1",
            // Exit if TorDrop dies before TAKEOWNERSHIP is in effect.
            "--__OwningControllerProcess", String(ProcessInfo.processInfo.processIdentifier)
        ]
        // Tor Browser's tor loads its bundled libraries relative to itself.
        p.currentDirectoryURL = binary.deletingLastPathComponent()

        p.standardInput = FileHandle.nullDevice
        p.standardOutput = forwardLines(prefix: "tor")
        p.standardError = forwardLines(prefix: "tor(stderr)")

        stateLock.lock()
        defer { stateLock.unlock() }
        guard !cancelled else { throw CancellationError() }
        try p.run()
        process = p
    }

    /// A pipe whose output is forwarded to the log one line at a time.
    private func forwardLines(prefix: String) -> Pipe {
        let pipe = Pipe()
        var pending = Data()
        pipe.fileHandleForReading.readabilityHandler = { [weak self] fh in
            let data = fh.availableData
            guard !data.isEmpty else {
                // EOF: without this the handler is re-invoked in a busy loop.
                fh.readabilityHandler = nil
                if !pending.isEmpty { self?.log("\(prefix): \(String(decoding: pending, as: UTF8.self))") }
                return
            }
            pending.append(data)
            while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                let line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
                pending.removeSubrange(pending.startIndex...newline)
                if !line.isEmpty { self?.log("\(prefix): \(line)") }
            }
        }
        return pipe
    }

    private func waitForControlPortFile() throws {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            try checkCancelled()
            if let contents = try? String(contentsOf: controlPortFile, encoding: .utf8),
               TorControlParsing.controlPort(inPortFile: contents) != nil {
                return
            }
            if let p = process, !p.isRunning {
                throw TorError.processDied(p.terminationStatus)
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw TorError.timeout("tor did not open its control port")
    }

    // MARK: Control connection

    private func connectAndAuthenticate(port: UInt16) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw TorError.controlConnectionFailed("socket() failed: \(String(cString: strerror(errno)))")
        }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let connectResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                Darwin.connect(fd, saPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connectResult == 0 else {
            let msg = String(cString: strerror(errno))
            Darwin.close(fd)
            throw TorError.controlConnectionFailed("connect() failed: \(msg)")
        }

        stateLock.lock()
        let wasCancelled = cancelled
        if !wasCancelled { controlSocket = fd }
        stateLock.unlock()
        if wasCancelled {
            Darwin.close(fd)
            throw CancellationError()
        }

        let cookie = try Data(contentsOf: cookieFile)
        let hex = cookie.map { String(format: "%02x", $0) }.joined()
        try sendCommand("AUTHENTICATE \(hex)")
    }

    private func waitForBootstrap() throws {
        // Measured from the last observed progress, so a slow but advancing
        // bootstrap is not cut off.
        var deadline = Date().addingTimeInterval(90)
        var lastProgress = -1
        while true {
            let reply = try sendCommand("GETINFO status/bootstrap-phase")
            if let status = reply.lines.lazy.compactMap(TorBootstrapStatus.init(line:)).first {
                if status.isDone { return }
                if status.progress != lastProgress {
                    lastProgress = status.progress
                    deadline = Date().addingTimeInterval(90)
                    let summary = status.summary ?? "Connecting to the Tor network"
                    progressHandler("\(summary) (\(status.progress)%)", Double(status.progress) / 100)
                }
            }
            if Date() >= deadline { throw TorError.bootstrapTimeout }
            try checkCancelled()
            Thread.sleep(forTimeInterval: 0.4)
        }
    }

    /// Waits until tor reports it has uploaded the service descriptor to at
    /// least one HSDir, so the address works when first shared. Falls back to
    /// returning after `timeout`; tor keeps retrying the upload regardless.
    private func waitForDescriptorUpload(serviceID: String, timeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !uploadedDescriptors.contains(serviceID) {
            guard Date() < deadline else {
                log("Descriptor upload not yet confirmed; the address may take a minute to become reachable.")
                return
            }
            do {
                let reply = try readReply(deadline: deadline)
                if reply.isAsyncEvent { handleEvent(reply) }
            } catch TorError.timeout {
                continue
            }
        }
        log("Onion service descriptor published.")
    }

    private func handleEvent(_ reply: TorControlReply) {
        guard let event = TorControlParsing.hiddenServiceDescriptorEvent(in: reply) else { return }
        switch event.action {
        case "UPLOADED":
            uploadedDescriptors.insert(event.address)
        case "FAILED":
            log("Descriptor upload to an HSDir failed; tor will retry.")
        default:
            break
        }
    }

    // MARK: Low-level socket IO

    @discardableResult
    private func sendCommand(_ command: String, timeout: TimeInterval = 30) throws -> TorControlReply {
        try checkCancelled()
        let fd = controlSocket
        guard fd >= 0 else {
            throw TorError.controlConnectionFailed("Socket not open")
        }
        let payload = Data((command + "\r\n").utf8)
        try payload.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
            var total = 0
            let base = ptr.baseAddress!
            while total < payload.count {
                let n = Darwin.write(fd, base.advanced(by: total), payload.count - total)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 {
                    try checkCancelled()
                    throw TorError.controlConnectionFailed(
                        "write() failed: \(String(cString: strerror(errno)))")
                }
                total += n
            }
        }

        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let reply = try readReply(deadline: deadline)
            if reply.isAsyncEvent {
                handleEvent(reply)
                continue
            }
            guard reply.isSuccess else {
                let verb = command.split(separator: " ").first.map(String.init) ?? command
                throw TorError.controlProtocolError("\(verb): \(reply.code) \(reply.text)")
            }
            return reply
        }
    }

    /// Reads the next complete reply (including async events). Polls in short
    /// slices so cancellation is noticed promptly.
    private func readReply(deadline: Date) throws -> TorControlReply {
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            if let reply = parser.nextReply() { return reply }
            try checkCancelled()

            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw TorError.timeout("no reply on the control port") }

            var pfd = pollfd(fd: controlSocket, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, Int32(min(remaining, 0.5) * 1000))
            if ready < 0 {
                if errno == EINTR { continue }
                throw TorError.controlConnectionFailed("poll() failed: \(String(cString: strerror(errno)))")
            }
            if ready == 0 { continue }

            let n = Darwin.read(controlSocket, &chunk, chunk.count)
            if n < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            if n <= 0 {
                try checkCancelled()
                if let p = process, !p.isRunning { throw TorError.processDied(p.terminationStatus) }
                throw TorError.controlConnectionFailed(
                    n == 0 ? "tor closed the control connection" : String(cString: strerror(errno)))
            }
            parser.append(Data(chunk[0..<n]))
        }
    }

    private func log(_ msg: String) { logHandler(msg) }
}
