import Foundation
import Darwin

enum TorError: LocalizedError {
    case binaryNotFound
    case bootstrapTimeout
    case controlConnectionFailed(String)
    case controlProtocolError(String)
    case processDied(Int32)

    var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            return "tor binary not found. Install with: brew install tor"
        case .bootstrapTimeout:
            return "Tor failed to bootstrap within the timeout."
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
/// (Flags=DiscardPK) — the service dies with the tor process.
final class TorController {
    private let dataDirectory: URL
    private let controlPortFile: URL
    private let cookieFile: URL
    private var process: Process?
    private var controlSocket: Int32 = -1
    private var onionServiceID: String?

    private let logHandler: (String) -> Void

    init(logHandler: @escaping (String) -> Void) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("tordrop-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        self.dataDirectory = tmp
        self.controlPortFile = tmp.appendingPathComponent("control-port")
        self.cookieFile = tmp.appendingPathComponent("control_auth_cookie")
        self.logHandler = logHandler
    }

    // MARK: Public API

    /// Starts tor, waits for bootstrap, and publishes a v3 hidden service
    /// forwarding onion port 80 → 127.0.0.1:<localPort>. Returns the `.onion`
    /// hostname (without scheme).
    func start(forwardingToLocalPort localPort: UInt16) async throws -> String {
        let binary = try Self.findTorBinary()
        log("Using tor at \(binary.path)")

        try launchProcess(binary: binary)
        try await waitForControlPortFile()
        let port = try readControlPort()
        log("Tor control port: \(port)")

        try connectAndAuthenticate(port: port)
        try sendCommand("TAKEOWNERSHIP")

        try await waitForBootstrap()
        log("Tor bootstrapped. Creating onion service…")

        let serviceID = try createOnionService(localPort: localPort)
        onionServiceID = serviceID
        log("Onion service published: \(serviceID).onion")
        return "\(serviceID).onion"
    }

    func stop() {
        if let sid = onionServiceID {
            _ = try? sendCommand("DEL_ONION \(sid)")
        }
        if controlSocket >= 0 {
            Darwin.close(controlSocket)
            controlSocket = -1
        }
        if let p = process, p.isRunning {
            p.terminate()
            // Give tor a moment to exit cleanly.
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [p] in
                if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            }
        }
        try? FileManager.default.removeItem(at: dataDirectory)
    }

    // MARK: Binary discovery

    private static func findTorBinary() throws -> URL {
        let candidates = [
            "/opt/homebrew/bin/tor",
            "/usr/local/bin/tor",
            "/opt/local/bin/tor",
            "/usr/bin/tor"
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }

        // Fall back to `which tor`
        let which = Process()
        which.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        which.arguments = ["which", "tor"]
        let pipe = Pipe()
        which.standardOutput = pipe
        which.standardError = Pipe()
        try? which.run()
        which.waitUntilExit()
        if which.terminationStatus == 0,
           let data = try? pipe.fileHandleForReading.readToEnd(),
           let path = String(data: data, encoding: .utf8)?
               .trimmingCharacters(in: .whitespacesAndNewlines),
           !path.isEmpty,
           FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        throw TorError.binaryNotFound
    }

    // MARK: Process lifecycle

    private func launchProcess(binary: URL) throws {
        let p = Process()
        p.executableURL = binary
        p.arguments = [
            "--DataDirectory", dataDirectory.path,
            "--SOCKSPort", "0",
            "--ControlPort", "auto",
            "--ControlPortWriteToFile", controlPortFile.path,
            "--CookieAuthentication", "1",
            "--CookieAuthFile", cookieFile.path,
            "--Log", "notice stdout",
            "--ClientOnly", "1",
            "--AvoidDiskWrites", "1"
        ]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        p.standardOutput = stdoutPipe
        p.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] fh in
            let data = fh.availableData
            guard !data.isEmpty, let line = String(data: data, encoding: .utf8) else { return }
            for l in line.split(separator: "\n") where !l.isEmpty {
                self?.log("tor: \(l)")
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] fh in
            let data = fh.availableData
            guard !data.isEmpty, let line = String(data: data, encoding: .utf8) else { return }
            for l in line.split(separator: "\n") where !l.isEmpty {
                self?.log("tor(stderr): \(l)")
            }
        }

        try p.run()
        process = p
    }

    private func waitForControlPortFile() async throws {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: controlPortFile.path),
               let contents = try? String(contentsOf: controlPortFile, encoding: .utf8),
               contents.contains("PORT=") {
                return
            }
            if let p = process, !p.isRunning {
                throw TorError.processDied(p.terminationStatus)
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        throw TorError.bootstrapTimeout
    }

    private func readControlPort() throws -> UInt16 {
        let contents = try String(contentsOf: controlPortFile, encoding: .utf8)
        // Format: PORT=127.0.0.1:58739
        guard let eq = contents.firstIndex(of: "="),
              let colon = contents[eq...].firstIndex(of: ":") else {
            throw TorError.controlProtocolError("Cannot parse control port file")
        }
        let portStr = contents[contents.index(after: colon)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let port = UInt16(portStr) else {
            throw TorError.controlProtocolError("Invalid control port: \(portStr)")
        }
        return port
    }

    // MARK: Control socket

    private func connectAndAuthenticate(port: UInt16) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw TorError.controlConnectionFailed("socket() failed: \(String(cString: strerror(errno)))")
        }

        var addr = sockaddr_in()
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
        controlSocket = fd

        let cookie = try Data(contentsOf: cookieFile)
        let hex = cookie.map { String(format: "%02x", $0) }.joined()
        try sendCommand("AUTHENTICATE \(hex)")
    }

    private func waitForBootstrap() async throws {
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            let response = try sendCommand("GETINFO status/bootstrap-phase")
            if response.contains("PROGRESS=100") || response.contains("TAG=done") {
                return
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        throw TorError.bootstrapTimeout
    }

    private func createOnionService(localPort: UInt16) throws -> String {
        let response = try sendCommand(
            "ADD_ONION NEW:ED25519-V3 Flags=DiscardPK Port=80,127.0.0.1:\(localPort)"
        )
        // Response contains a line: 250-ServiceID=<56chars>
        for line in response.components(separatedBy: "\r\n") {
            if let range = line.range(of: "ServiceID=") {
                return String(line[range.upperBound...])
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        throw TorError.controlProtocolError("No ServiceID in ADD_ONION response:\n\(response)")
    }

    // MARK: Low-level socket IO

    @discardableResult
    private func sendCommand(_ command: String) throws -> String {
        guard controlSocket >= 0 else {
            throw TorError.controlConnectionFailed("Socket not open")
        }
        let payload = (command + "\r\n").data(using: .utf8)!
        try payload.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
            var total = 0
            let base = ptr.baseAddress!
            while total < payload.count {
                let n = Darwin.write(controlSocket, base.advanced(by: total),
                                     payload.count - total)
                if n <= 0 {
                    throw TorError.controlConnectionFailed(
                        "write() failed: \(String(cString: strerror(errno)))")
                }
                total += n
            }
        }
        return try readResponse()
    }

    private func readResponse() throws -> String {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = Darwin.read(controlSocket, &chunk, chunk.count)
            if n <= 0 {
                throw TorError.controlConnectionFailed(
                    "read() failed: \(String(cString: strerror(errno)))")
            }
            buffer.append(chunk, count: n)
            // A complete tor control reply ends with a line "XYZ <text>\r\n"
            // where position 3 is a space (not '-' or '+').
            if let str = String(data: buffer, encoding: .utf8),
               let terminator = Self.responseTerminator(in: str) {
                let complete = String(str.prefix(upTo: terminator))
                let code = complete.prefix(3)
                if !code.hasPrefix("250") {
                    throw TorError.controlProtocolError(complete)
                }
                return complete
            }
        }
    }

    /// Returns the index immediately after a terminator line (code followed by space).
    private static func responseTerminator(in str: String) -> String.Index? {
        let lines = str.components(separatedBy: "\r\n")
        var offset = str.startIndex
        for line in lines {
            let end = str.index(offset, offsetBy: line.count)
            if line.count >= 4,
               line[line.index(line.startIndex, offsetBy: 3)] == " " {
                // Include the trailing \r\n
                let afterCRLF = str.index(end, offsetBy: 2, limitedBy: str.endIndex) ?? str.endIndex
                return afterCRLF
            }
            offset = str.index(end, offsetBy: 2, limitedBy: str.endIndex) ?? str.endIndex
            if offset == str.endIndex { break }
        }
        return nil
    }

    private func log(_ msg: String) { logHandler(msg) }
}
