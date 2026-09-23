import Foundation
import Network
import UniformTypeIdentifiers

/// Minimal HTTP/1.1 server bound to 127.0.0.1 that serves an HTML index of
/// shared files and streams individual file downloads (with Range support so
/// interrupted downloads can resume). All paths live under a random URL slug
/// so that the raw onion address alone is not a direct handle on the files.
final class FileServer {
    struct Entry {
        /// Unique name the file is served under.
        let name: String
        let url: URL
        let size: Int64
    }

    enum Event {
        /// A GET for `name` started streaming.
        case transferStarted(name: String)
        /// A transfer ended. `completed` is true when the last byte of the
        /// file was handed to the network.
        case transferEnded(name: String, completed: Bool)
    }

    private(set) var port: UInt16 = 0
    let urlSlug: String

    private let listener: NWListener
    private let queue = DispatchQueue(label: "tordrop.fileserver", qos: .userInitiated)
    private var entries: [String: Entry] = [:]      // keyed by served name
    private let entriesLock = NSLock()

    // Touched only on `queue`.
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var stopped = false

    private let onEvent: (Event) -> Void
    private let logHandler: (String) -> Void

    private static let headerTimeout: TimeInterval = 30
    private static let maxHeaderBytes = 64 * 1024
    private static let chunkSize = 64 * 1024

    init(onEvent: @escaping (Event) -> Void,
         logHandler: @escaping (String) -> Void) throws {
        self.onEvent = onEvent
        self.logHandler = logHandler
        self.urlSlug = HTTPText.randomSlug(length: 20)

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: .ipv4(.loopback),
            port: .any
        )
        self.listener = try NWListener(using: params)
    }

    // MARK: Shared files

    /// Adds files to the share and returns their entries. Throws if any file
    /// cannot be read, in which case nothing is added.
    @discardableResult
    func add(files: [URL]) throws -> [Entry] {
        var pending: [(URL, Int64)] = []
        for url in files {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else {
                throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: url.path])
            }
            guard FileManager.default.isReadableFile(atPath: url.path) else {
                throw CocoaError(.fileReadNoPermission, userInfo: [NSFilePathErrorKey: url.path])
            }
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            pending.append((url, (attrs[.size] as? NSNumber)?.int64Value ?? 0))
        }

        entriesLock.lock()
        defer { entriesLock.unlock() }
        var added: [Entry] = []
        for (url, size) in pending {
            let name = HTTPText.uniqueFilename(url.lastPathComponent, existing: Set(entries.keys))
            let entry = Entry(name: name, url: url, size: size)
            entries[name] = entry
            added.append(entry)
        }
        return added
    }

    func remove(name: String) {
        entriesLock.lock()
        entries[name] = nil
        entriesLock.unlock()
    }

    // MARK: Lifecycle

    func start() async throws {
        listener.newConnectionHandler = { [weak self] conn in
            self?.handle(connection: conn)
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var resumed = false
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if let p = self?.listener.port?.rawValue {
                        self?.port = p
                        self?.log("HTTP listening on 127.0.0.1:\(p)")
                    }
                    if !resumed { resumed = true; continuation.resume() }
                case .failed(let err):
                    self?.log("HTTP listener failed: \(err)")
                    if !resumed { resumed = true; continuation.resume(throwing: err) }
                case .cancelled:
                    if !resumed { resumed = true; continuation.resume(throwing: CancellationError()) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    /// Stops listening and drops every open connection, aborting in-flight
    /// downloads.
    func stop() {
        listener.cancel()
        queue.async { [self] in
            stopped = true
            for conn in connections.values { conn.cancel() }
            connections.removeAll()
        }
    }

    // MARK: Connection handling (on `queue`)

    private func handle(connection conn: NWConnection) {
        guard !stopped else { conn.cancel(); return }
        let id = ObjectIdentifier(conn)
        connections[id] = conn
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.connections[id] = nil
            default:
                break
            }
        }
        conn.start(queue: queue)

        // Drop clients that never finish sending a request.
        var gotRequest = false
        queue.asyncAfter(deadline: .now() + Self.headerTimeout) { [weak conn] in
            if !gotRequest { conn?.cancel() }
        }
        receiveRequest(conn: conn, accumulated: Data()) { gotRequest = true }
    }

    private func receiveRequest(conn: NWConnection, accumulated: Data, onRequest: @escaping () -> Void) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self = self else { conn.cancel(); return }
            if let error = error {
                self.log("recv error: \(error)")
                conn.cancel()
                return
            }
            var buffer = accumulated
            if let data = data { buffer.append(data) }

            if let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
                onRequest()
                let headerData = buffer.subdata(in: 0..<headerEnd.lowerBound)
                if let raw = String(data: headerData, encoding: .utf8),
                   let request = HTTPRequestHead(raw) {
                    self.route(request, on: conn)
                } else {
                    self.writeSimple(conn: conn, status: "400 Bad Request", body: "Bad Request")
                }
            } else if isComplete {
                conn.cancel()
            } else if buffer.count > Self.maxHeaderBytes {
                onRequest()
                self.writeSimple(conn: conn, status: "431 Request Header Fields Too Large",
                                 body: "Headers too large")
            } else {
                self.receiveRequest(conn: conn, accumulated: buffer, onRequest: onRequest)
            }
        }
    }

    private func route(_ request: HTTPRequestHead, on conn: NWConnection) {
        guard request.method == "GET" || request.method == "HEAD" else {
            writeSimple(conn: conn, status: "405 Method Not Allowed", body: "Method Not Allowed",
                        extraHeaders: ["Allow: GET, HEAD"])
            return
        }
        let headOnly = request.method == "HEAD"
        let prefix = "/\(urlSlug)"

        if request.path == prefix {
            // Relative links on the index only resolve under the trailing slash.
            writeSimple(conn: conn, status: "301 Moved Permanently", body: "Moved",
                        extraHeaders: ["Location: \(prefix)/"])
            return
        }
        guard request.path.hasPrefix(prefix + "/") else {
            writeSimple(conn: conn, status: "404 Not Found", body: "Not Found")
            return
        }

        let filename = String(request.path.dropFirst(prefix.count + 1))
        if filename.isEmpty {
            serveIndex(on: conn, headOnly: headOnly)
            return
        }

        entriesLock.lock()
        let entry = entries[filename]
        entriesLock.unlock()

        guard let entry = entry else {
            writeSimple(conn: conn, status: "404 Not Found", body: "Not Found")
            return
        }
        serveFile(entry: entry, request: request, on: conn, headOnly: headOnly)
    }

    // MARK: Responses

    private static let commonHeaders = [
        "Cache-Control: no-store",
        "Referrer-Policy: no-referrer",
        "X-Content-Type-Options: nosniff",
        "X-Frame-Options: DENY",
        "Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'none'",
        "Connection: close"
    ]

    private static func responseHead(status: String, headers: [String]) -> Data {
        let lines = ["HTTP/1.1 \(status)"] + headers + commonHeaders
        return Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    }

    private func serveIndex(on conn: NWConnection, headOnly: Bool) {
        entriesLock.lock()
        let snapshot = Array(entries.values)
        entriesLock.unlock()

        let sorted = snapshot.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        var rows = ""
        for entry in sorted {
            rows += """
            <tr>
              <td><a href="\(HTTPText.htmlEscape(HTTPText.relativeHref(for: entry.name)))" download>\(HTTPText.htmlEscape(entry.name))</a></td>
              <td class="size">\(Self.formatBytes(entry.size))</td>
            </tr>

            """
        }
        if sorted.isEmpty {
            rows = "<tr><td colspan=\"2\" class=\"empty\">No files are being shared right now.</td></tr>"
        }
        let total = sorted.reduce(Int64(0)) { $0 + $1.size }
        let summary = sorted.count == 1
            ? "1 file · \(Self.formatBytes(total))"
            : "\(sorted.count) files · \(Self.formatBytes(total))"

        let html = """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <meta name="referrer" content="no-referrer">
          <title>TorDrop</title>
          <style>
            body { font-family: -apple-system, system-ui, sans-serif; max-width: 640px;
                   margin: 4rem auto; padding: 0 1rem; color: #222; background: #fff; }
            h1 { font-size: 1.4rem; }
            .hint { color: #666; font-size: 0.9rem; }
            table { width: 100%; border-collapse: collapse; margin-top: 1.5rem; }
            th, td { padding: 0.6rem 0.4rem; border-bottom: 1px solid #eee; text-align: left;
                     overflow-wrap: anywhere; }
            td.size, th.size { text-align: right; color: #666; font-variant-numeric: tabular-nums;
                               white-space: nowrap; }
            td.empty { color: #666; text-align: center; }
            a { color: #5b3eb1; text-decoration: none; }
            a:hover { text-decoration: underline; }
            @media (prefers-color-scheme: dark) {
              body { color: #eee; background: #1c1b22; }
              th, td { border-bottom-color: #333; }
              .hint, td.size, th.size, td.empty { color: #aaa; }
              a { color: #b9a4ff; }
            }
          </style>
        </head>
        <body>
          <h1>TorDrop</h1>
          <p class="hint">Shared files: click to download. \(summary)</p>
          <table>
            <thead><tr><th>File</th><th class="size">Size</th></tr></thead>
            <tbody>\(rows)</tbody>
          </table>
        </body>
        </html>
        """

        let body = Data(html.utf8)
        let head = Self.responseHead(status: "200 OK", headers: [
            "Content-Type: text/html; charset=utf-8",
            "Content-Length: \(body.count)"
        ])
        var payload = head
        if !headOnly { payload.append(body) }
        conn.send(content: payload, isComplete: true,
                  completion: .contentProcessed { _ in conn.cancel() })
    }

    private func serveFile(entry: Entry, request: HTTPRequestHead, on conn: NWConnection, headOnly: Bool) {
        guard let handle = try? FileHandle(forReadingFrom: entry.url),
              let size = try? handle.seekToEnd() else {
            log("Cannot open \(entry.name)")
            writeSimple(conn: conn, status: "500 Internal Server Error", body: "Cannot open file")
            return
        }
        // Size at serve time, so a file that changed since it was shared still
        // gets an accurate Content-Length.
        let fileSize = Int64(size)
        let etag = Self.etag(for: entry.url, size: fileSize)

        var range = HTTPByteRange.evaluate(request.headers["range"], size: fileSize)
        if let ifRange = request.headers["if-range"], ifRange != etag {
            range = .full
        }

        var headers = [
            "Content-Type: \(Self.mimeType(for: entry.url))",
            "Content-Disposition: \(HTTPText.contentDisposition(filename: entry.name))",
            "Accept-Ranges: bytes",
            "ETag: \(etag)"
        ]
        let status: String
        let start: Int64
        let end: Int64
        switch range {
        case .unsatisfiable:
            try? handle.close()
            writeSimple(conn: conn, status: "416 Range Not Satisfiable", body: "Range Not Satisfiable",
                        extraHeaders: ["Content-Range: bytes */\(fileSize)"])
            return
        case .full:
            status = "200 OK"
            start = 0
            end = fileSize - 1
        case .partial(let s, let e):
            status = "206 Partial Content"
            start = s
            end = e
            headers.append("Content-Range: bytes \(s)-\(e)/\(fileSize)")
        }
        let length = max(0, end - start + 1)
        headers.append("Content-Length: \(length)")
        let head = Self.responseHead(status: status, headers: headers)

        if headOnly {
            try? handle.close()
            conn.send(content: head, isComplete: true, completion: .contentProcessed { _ in conn.cancel() })
            return
        }

        do {
            try handle.seek(toOffset: UInt64(start))
        } catch {
            try? handle.close()
            writeSimple(conn: conn, status: "500 Internal Server Error", body: "Cannot read file")
            return
        }

        let rangeNote = range == .full ? "" : " [bytes \(start)-\(end)]"
        log("→ \(entry.name) (\(length) bytes)\(rangeNote)")
        onEvent(.transferStarted(name: entry.name))
        let reachesEOF = end == fileSize - 1

        conn.send(content: head, completion: .contentProcessed { [self] err in
            if err != nil {
                finishTransfer(entry.name, handle: handle, conn: conn, completed: false)
                return
            }
            streamFile(name: entry.name, handle: handle, remaining: length, reachesEOF: reachesEOF, on: conn)
        })
    }

    private func streamFile(name: String, handle: FileHandle, remaining: Int64, reachesEOF: Bool,
                            on conn: NWConnection) {
        if remaining <= 0 {
            conn.send(content: nil, isComplete: true, completion: .contentProcessed { [self] err in
                finishTransfer(name, handle: handle, conn: conn, completed: err == nil && reachesEOF)
            })
            return
        }

        let data: Data
        do {
            data = try handle.read(upToCount: Int(min(Int64(Self.chunkSize), remaining))) ?? Data()
        } catch {
            log("read error: \(error)")
            finishTransfer(name, handle: handle, conn: conn, completed: false)
            return
        }
        if data.isEmpty {
            // The file shrank since the headers were sent; the client will see
            // a short body and can retry.
            log("\(name) ended early; was it modified while shared?")
            finishTransfer(name, handle: handle, conn: conn, completed: false)
            return
        }
        conn.send(content: data, isComplete: false, completion: .contentProcessed { [self] err in
            if err != nil {
                finishTransfer(name, handle: handle, conn: conn, completed: false)
                return
            }
            streamFile(name: name, handle: handle, remaining: remaining - Int64(data.count),
                       reachesEOF: reachesEOF, on: conn)
        })
    }

    private func finishTransfer(_ name: String, handle: FileHandle, conn: NWConnection, completed: Bool) {
        try? handle.close()
        conn.cancel()
        onEvent(.transferEnded(name: name, completed: completed))
        if !completed { log("Transfer of \(name) did not finish.") }
    }

    private func writeSimple(conn: NWConnection, status: String, body: String, extraHeaders: [String] = []) {
        let bodyData = Data(body.utf8)
        var payload = Self.responseHead(status: status, headers: [
            "Content-Type: text/plain; charset=utf-8",
            "Content-Length: \(bodyData.count)"
        ] + extraHeaders)
        payload.append(bodyData)
        conn.send(content: payload, isComplete: true,
                  completion: .contentProcessed { _ in conn.cancel() })
    }

    private func log(_ msg: String) { logHandler(msg) }

    // MARK: Helpers

    private static func etag(for url: URL, size: Int64) -> String {
        // Hasher is randomly seeded per process, so the tag reveals nothing
        // about the file's timestamps but still changes if the file does.
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate?.timeIntervalSinceReferenceDate ?? 0
        var hasher = Hasher()
        hasher.combine(url.path)
        hasher.combine(size)
        hasher.combine(modified)
        return "\"\(String(UInt64(bitPattern: Int64(hasher.finalize())), radix: 16))\""
    }

    private static func mimeType(for url: URL) -> String {
        if let type = UTType(filenameExtension: url.pathExtension),
           let mime = type.preferredMIMEType {
            return mime
        }
        return "application/octet-stream"
    }

    private static func formatBytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }
}
