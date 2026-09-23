import Foundation

/// The request line and headers of an HTTP/1.x request.
struct HTTPRequestHead: Equatable {
    let method: String
    /// Percent-decoded path with any query string or fragment removed.
    let path: String
    /// Header values keyed by lowercased header name.
    let headers: [String: String]

    init?(_ raw: String) {
        let lines = raw.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }

        var target = String(parts[1])
        if let cut = target.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            target = String(target[..<cut])
        }
        guard target.hasPrefix("/"), let decoded = target.removingPercentEncoding else { return nil }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        self.method = String(parts[0])
        self.path = decoded
        self.headers = headers
    }
}

/// Outcome of evaluating a `Range` request header against a file size.
enum HTTPByteRange: Equatable {
    /// No (usable) Range header: send the whole file with 200.
    case full
    /// Send bytes `start...end` (inclusive) with 206.
    case partial(start: Int64, end: Int64)
    /// The range lies outside the file: send 416.
    case unsatisfiable

    /// Evaluates a single-range `bytes=` header. Syntactically invalid or
    /// multi-range headers are ignored, which RFC 9110 permits.
    static func evaluate(_ header: String?, size: Int64) -> HTTPByteRange {
        guard let header = header?.trimmingCharacters(in: .whitespaces),
              header.lowercased().hasPrefix("bytes=") else { return .full }
        let spec = header.dropFirst("bytes=".count).trimmingCharacters(in: .whitespaces)
        guard !spec.contains(",") else { return .full }
        let bounds = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard bounds.count == 2 else { return .full }
        let first = bounds[0].trimmingCharacters(in: .whitespaces)
        let last = bounds[1].trimmingCharacters(in: .whitespaces)
        guard first.allSatisfy(\.isASCIIDigit), last.allSatisfy(\.isASCIIDigit) else { return .full }

        if first.isEmpty {
            // Suffix range: the final N bytes.
            guard let count = Int64(last) else { return .full }
            guard count > 0, size > 0 else { return .unsatisfiable }
            return .partial(start: max(0, size - count), end: size - 1)
        }

        guard let start = Int64(first) else { return .full }
        var end = size - 1
        if !last.isEmpty {
            guard let requestedEnd = Int64(last), requestedEnd >= start else { return .full }
            end = min(requestedEnd, size - 1)
        }
        guard start < size else { return .unsatisfiable }
        return .partial(start: start, end: end)
    }
}

private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}

enum HTTPText {
    static func htmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
         .replacingOccurrences(of: "'", with: "&#39;")
    }

    /// Relative link to a file in the current directory. The "./" prefix
    /// stops names like "a:b.txt" from being parsed as a URL scheme.
    static func relativeHref(for filename: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#;%")
        return "./" + (filename.addingPercentEncoding(withAllowedCharacters: allowed) ?? filename)
    }

    /// `Content-Disposition` value with an ASCII fallback and an RFC 5987
    /// UTF-8 filename.
    static func contentDisposition(filename: String) -> String {
        let fallback = String(filename.unicodeScalars.map { scalar -> Character in
            if scalar.isASCII, scalar.value >= 0x20, scalar.value != 0x7F,
               scalar != "\"", scalar != "\\", scalar != "%" {
                return Character(scalar)
            }
            return "_"
        })
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encoded = filename.addingPercentEncoding(withAllowedCharacters: allowed) ?? fallback
        return "attachment; filename=\"\(fallback)\"; filename*=UTF-8''\(encoded)"
    }

    /// Makes a display filename safe to use as a single URL path segment and
    /// unique among `existing`.
    static func uniqueFilename(_ raw: String, existing: Set<String>) -> String {
        var cleaned = String(raw.map { ch -> Character in
            ch == "/" || ch == "\\" || ch.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
                ? "_" : ch
        })
        if cleaned.isEmpty || cleaned == "." || cleaned == ".." { cleaned = "file" }
        if !existing.contains(cleaned) { return cleaned }

        let ext = (cleaned as NSString).pathExtension
        let base = (cleaned as NSString).deletingPathExtension
        var i = 2
        while true {
            let candidate = ext.isEmpty ? "\(base) (\(i))" : "\(base) (\(i)).\(ext)"
            if !existing.contains(candidate) { return candidate }
            i += 1
        }
    }

    /// Random lowercase alphanumeric string, drawn without modulo bias.
    static func randomSlug(length: Int) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        var generator = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in alphabet.randomElement(using: &generator)! })
    }
}
