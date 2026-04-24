import Foundation
import Network
import UniformTypeIdentifiers

/// Minimal HTTP/1.1 server bound to 127.0.0.1 that serves an HTML index of
/// shared files and streams individual file downloads. All paths live under a
/// random URL slug so that the raw onion address alone is not a direct handle
/// on the files.
final class FileServer {
    struct Entry {
        let url: URL
        let size: Int64
    }

    private(set) var port: UInt16 = 0
    let urlSlug: String

    private let listener: NWListener
    private let queue = DispatchQueue(label: "tordrop.fileserver", qos: .userInitiated)
    private var entries: [String: Entry] = [:]      // keyed by filename
    private let entriesLock = NSLock()

    private let onDownload: (URL) -> Void
    private let logHandler: (String) -> Void

    init(files: [URL],
         onDownload: @escaping (URL) -> Void,
         logHandler: @escaping (String) -> Void) throws {
        self.onDownload = onDownload
        self.logHandler = logHandler
        self.urlSlug = Self.randomSlug(length: 20)

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: .ipv4(.loopback),
            port: .any
        )
        self.listener = try NWListener(using: params)

        for url in files {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            let name = Self.sanitize(filename: url.lastPathComponent, existing: entries)
            entries[name] = Entry(url: url, size: size)
        }
    }

    func start() throws {
        listener.newConnectionHandler = { [weak self] conn in
            self?.handle(connection: conn)
        }

        let ready = DispatchSemaphore(value: 0)
        var startError: Error?
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                if let p = self?.listener.port?.rawValue {
                    self?.port = p
                    self?.log("HTTP listening on 127.0.0.1:\(p)")
                }
                ready.signal()
            case .failed(let err):
                startError = err
                ready.signal()
            default:
                break
            }
        }
        listener.start(queue: queue)

        let result = ready.wait(timeout: .now() + 5)
        if result == .timedOut {
            throw NSError(domain: "FileServer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Listener did not become ready."])
        }
        if let err = startError { throw err }
    }

    func stop() {
        listener.cancel()
    }

    // MARK: Connection handling

    private func handle(connection conn: NWConnection) {
        conn.start(queue: queue)
        receiveRequest(conn: conn, accumulated: Data())
    }

    private func receiveRequest(conn: NWConnection, accumulated: Data) {
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
                let headerData = buffer.subdata(in: 0..<headerEnd.lowerBound)
                if let headerStr = String(data: headerData, encoding: .utf8) {
                    self.route(request: headerStr, on: conn)
                } else {
                    self.writeSimple(conn: conn, status: "400 Bad Request", body: "Bad Request")
                }
            } else if isComplete {
                conn.cancel()
            } else if buffer.count > 64 * 1024 {
                self.writeSimple(conn: conn, status: "431 Request Header Fields Too Large",
                                 body: "Headers too large")
            } else {
                self.receiveRequest(conn: conn, accumulated: buffer)
            }
        }
    }

    private func route(request: String, on conn: NWConnection) {
        let lines = request.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            writeSimple(conn: conn, status: "400 Bad Request", body: "Bad Request")
            return
        }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            writeSimple(conn: conn, status: "400 Bad Request", body: "Bad Request")
            return
        }
        let method = String(parts[0])
        let rawPath = String(parts[1])

        guard method == "GET" || method == "HEAD" else {
            writeSimple(conn: conn, status: "405 Method Not Allowed", body: "Method Not Allowed")
            return
        }

        let path = rawPath.removingPercentEncoding ?? rawPath
        let prefix = "/\(urlSlug)"

        guard path == prefix || path.hasPrefix(prefix + "/") else {
            writeSimple(conn: conn, status: "404 Not Found", body: "Not Found")
            return
        }

        let remainder = String(path.dropFirst(prefix.count))
        if remainder.isEmpty || remainder == "/" {
            serveIndex(on: conn, headOnly: method == "HEAD")
            return
        }

        // remainder starts with "/"
        let filename = String(remainder.dropFirst())
        entriesLock.lock()
        let entry = entries[filename]
        entriesLock.unlock()

        guard let entry = entry else {
            writeSimple(conn: conn, status: "404 Not Found", body: "Not Found")
            return
        }
        serveFile(entry: entry, filename: filename, on: conn, headOnly: method == "HEAD")
    }

    // MARK: Responses

    private func serveIndex(on conn: NWConnection, headOnly: Bool) {
        entriesLock.lock()
        let snapshot = entries
        entriesLock.unlock()

        var rows = ""
        let sorted = snapshot.sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
        for (name, entry) in sorted {
            let escaped = Self.htmlEscape(name)
            let href = Self.urlEncode(name)
            rows += """
            <tr>
              <td><a href="\(href)" download>\(escaped)</a></td>
              <td class="size">\(Self.formatBytes(entry.size))</td>
            </tr>
            """
        }

        let html = """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <title>TorDrop</title>
          <style>
            body { font-family: -apple-system, system-ui, sans-serif; max-width: 640px;
                   margin: 4rem auto; padding: 0 1rem; color: #222; }
            h1 { font-size: 1.4rem; }
            .hint { color: #666; font-size: 0.9rem; }
            table { width: 100%; border-collapse: collapse; margin-top: 1.5rem; }
            th, td { padding: 0.6rem 0.4rem; border-bottom: 1px solid #eee; text-align: left; }
            td.size, th.size { text-align: right; color: #666; font-variant-numeric: tabular-nums; }
            a { color: #5b3eb1; text-decoration: none; }
            a:hover { text-decoration: underline; }
          </style>
        </head>
        <body>
          <h1>TorDrop</h1>
          <p class="hint">Shared files — click to download.</p>
          <table>
            <thead><tr><th>File</th><th class="size">Size</th></tr></thead>
            <tbody>\(rows)</tbody>
          </table>
        </body>
        </html>
        """

        let body = Data(html.utf8)
        var header = "HTTP/1.1 200 OK\r\n"
        header += "Content-Type: text/html; charset=utf-8\r\n"
        header += "Content-Length: \(body.count)\r\n"
        header += "Connection: close\r\n\r\n"

        conn.send(content: Data(header.utf8), completion: .contentProcessed { _ in
            if headOnly {
                conn.send(content: nil, isComplete: true, completion: .contentProcessed { _ in
                    conn.cancel()
                })
            } else {
                conn.send(content: body, isComplete: true,
                          completion: .contentProcessed { _ in conn.cancel() })
            }
        })
    }

    private func serveFile(entry: Entry, filename: String, on conn: NWConnection, headOnly: Bool) {
        guard let handle = try? FileHandle(forReadingFrom: entry.url) else {
            writeSimple(conn: conn, status: "500 Internal Server Error", body: "Cannot open file")
            return
        }

        let mime = Self.mimeType(for: entry.url)
        let dispositionName = Self.rfc5987(filename)
        var header = "HTTP/1.1 200 OK\r\n"
        header += "Content-Type: \(mime)\r\n"
        header += "Content-Length: \(entry.size)\r\n"
        header += "Content-Disposition: attachment; filename*=UTF-8''\(dispositionName)\r\n"
        header += "Connection: close\r\n\r\n"

        onDownload(entry.url)
        log("→ \(filename) (\(entry.size) bytes)")

        conn.send(content: Data(header.utf8), completion: .contentProcessed { [weak self] err in
            if err != nil { try? handle.close(); conn.cancel(); return }
            if headOnly {
                try? handle.close()
                conn.send(content: nil, isComplete: true, completion: .contentProcessed { _ in
                    conn.cancel()
                })
                return
            }
            self?.streamFile(handle: handle, on: conn)
        })
    }

    private func streamFile(handle: FileHandle, on conn: NWConnection) {
        let chunkSize = 64 * 1024
        let data: Data
        do {
            data = try handle.read(upToCount: chunkSize) ?? Data()
        } catch {
            log("read error: \(error)")
            try? handle.close()
            conn.cancel()
            return
        }
        if data.isEmpty {
            try? handle.close()
            conn.send(content: nil, isComplete: true, completion: .contentProcessed { _ in
                conn.cancel()
            })
            return
        }
        conn.send(content: data, isComplete: false, completion: .contentProcessed { [weak self] err in
            if err != nil {
                try? handle.close()
                conn.cancel()
                return
            }
            self?.streamFile(handle: handle, on: conn)
        })
    }

    private func writeSimple(conn: NWConnection, status: String, body: String) {
        let bodyData = Data(body.utf8)
        var header = "HTTP/1.1 \(status)\r\n"
        header += "Content-Type: text/plain; charset=utf-8\r\n"
        header += "Content-Length: \(bodyData.count)\r\n"
        header += "Connection: close\r\n\r\n"
        var payload = Data(header.utf8)
        payload.append(bodyData)
        conn.send(content: payload, isComplete: true,
                  completion: .contentProcessed { _ in conn.cancel() })
    }

    private func log(_ msg: String) { logHandler(msg) }

    // MARK: Helpers

    private static func randomSlug(length: Int) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        var bytes = [UInt8](repeating: 0, count: length)
        _ = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        return String(bytes.map { alphabet[Int($0) % alphabet.count] })
    }

    private static func sanitize(filename raw: String, existing: [String: Entry]) -> String {
        let cleaned = raw.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
        if existing[cleaned] == nil { return cleaned }
        var i = 2
        let ext = (cleaned as NSString).pathExtension
        let base = (cleaned as NSString).deletingPathExtension
        while true {
            let candidate = ext.isEmpty ? "\(base) (\(i))" : "\(base) (\(i)).\(ext)"
            if existing[candidate] == nil { return candidate }
            i += 1
        }
    }

    private static func mimeType(for url: URL) -> String {
        if let type = UTType(filenameExtension: url.pathExtension),
           let mime = type.preferredMIMEType {
            return mime
        }
        return "application/octet-stream"
    }

    private static func htmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func urlEncode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? s
    }

    private static func rfc5987(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    private static func formatBytes(_ n: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: n)
    }
}
