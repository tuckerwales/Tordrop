import Foundation

/// A single reply from the tor control port (control-spec section 2.3).
struct TorControlReply: Equatable {
    /// Three-digit status code, or 0 when tor sent a line we could not parse.
    let code: Int
    /// Reply lines with the status code and separator stripped. A data block
    /// ("+" line) is folded into its keyword line, joined with "\n".
    let lines: [String]

    var isSuccess: Bool { code / 100 == 2 }
    var isAsyncEvent: Bool { code / 100 == 6 }
    var text: String { lines.joined(separator: "\n") }
}

/// Incremental parser for tor control replies. Feed it raw bytes as they
/// arrive from the socket and pull complete replies out; partial lines and
/// partial replies are buffered until the rest arrives.
struct TorControlReplyParser {
    private var buffer = Data()
    private var pendingLines: [String] = []
    private var dataBlockHeader: String?
    private var dataBlockLines: [String] = []
    private var pendingCode = 0
    private var replies: [TorControlReply] = []

    mutating func append(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            var lineData = buffer[buffer.startIndex..<newline]
            if lineData.last == UInt8(ascii: "\r") { lineData = lineData.dropLast() }
            buffer.removeSubrange(buffer.startIndex...newline)
            consume(line: String(decoding: lineData, as: UTF8.self))
        }
    }

    mutating func nextReply() -> TorControlReply? {
        replies.isEmpty ? nil : replies.removeFirst()
    }

    private mutating func consume(line: String) {
        if let header = dataBlockHeader {
            if line == "." {
                let block = ([header] + dataBlockLines).joined(separator: "\n")
                pendingLines.append(block)
                dataBlockHeader = nil
                dataBlockLines = []
            } else {
                // Leading dots are escaped by doubling them.
                dataBlockLines.append(line.hasPrefix("..") ? String(line.dropFirst()) : line)
            }
            return
        }

        let chars = Array(line)
        guard chars.count >= 4, let code = Int(String(chars[0..<3])) else {
            replies.append(TorControlReply(code: 0, lines: pendingLines + [line]))
            pendingLines = []
            return
        }
        pendingCode = code
        let rest = String(chars[4...])
        switch chars[3] {
        case "-":
            pendingLines.append(rest)
        case "+":
            dataBlockHeader = rest
        case " ":
            pendingLines.append(rest)
            replies.append(TorControlReply(code: pendingCode, lines: pendingLines))
            pendingLines = []
        default:
            replies.append(TorControlReply(code: 0, lines: pendingLines + [line]))
            pendingLines = []
        }
    }
}

/// Parsed form of `GETINFO status/bootstrap-phase` or a `STATUS_CLIENT
/// BOOTSTRAP` event, e.g.
/// `NOTICE BOOTSTRAP PROGRESS=45 TAG=loading_descriptors SUMMARY="Loading relay descriptors"`.
struct TorBootstrapStatus: Equatable {
    let progress: Int
    let tag: String?
    let summary: String?

    var isDone: Bool { progress >= 100 || tag == "done" }

    init(progress: Int, tag: String?, summary: String?) {
        self.progress = progress
        self.tag = tag
        self.summary = summary
    }

    init?(line: String) {
        let values = Self.keywordArguments(in: line)
        guard let progressString = values["PROGRESS"], let progress = Int(progressString) else {
            return nil
        }
        self.init(progress: progress, tag: values["TAG"], summary: values["SUMMARY"])
    }

    /// Extracts KEY=VALUE and KEY="quoted value" pairs from a control line.
    static func keywordArguments(in line: String) -> [String: String] {
        var result: [String: String] = [:]
        var index = line.startIndex
        while index < line.endIndex {
            while index < line.endIndex, line[index] == " " { index = line.index(after: index) }
            let keyStart = index
            while index < line.endIndex, line[index] != " ", line[index] != "=" {
                index = line.index(after: index)
            }
            let key = String(line[keyStart..<index])
            guard index < line.endIndex, line[index] == "=" else { continue }
            index = line.index(after: index)

            var value = ""
            if index < line.endIndex, line[index] == "\"" {
                index = line.index(after: index)
                while index < line.endIndex, line[index] != "\"" {
                    if line[index] == "\\" {
                        index = line.index(after: index)
                        guard index < line.endIndex else { break }
                    }
                    value.append(line[index])
                    index = line.index(after: index)
                }
                if index < line.endIndex { index = line.index(after: index) }
            } else {
                while index < line.endIndex, line[index] != " " {
                    value.append(line[index])
                    index = line.index(after: index)
                }
            }
            if !key.isEmpty { result[key] = value }
        }
        return result
    }
}

enum TorControlParsing {
    /// Returns the onion service ID from an ADD_ONION reply.
    static func serviceID(in reply: TorControlReply) -> String? {
        for line in reply.lines where line.hasPrefix("ServiceID=") {
            let id = line.dropFirst("ServiceID=".count).trimmingCharacters(in: .whitespaces)
            return id.isEmpty ? nil : id
        }
        return nil
    }

    /// Returns the port from a `ControlPortWriteToFile` file
    /// (`PORT=127.0.0.1:58739`).
    static func controlPort(inPortFile contents: String) -> UInt16? {
        for line in contents.split(whereSeparator: \.isNewline) where line.hasPrefix("PORT=") {
            guard let colon = line.lastIndex(of: ":") else { continue }
            if let port = UInt16(line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)) {
                return port
            }
        }
        return nil
    }

    /// Describes an HS_DESC event: returns the action (UPLOADED, FAILED,
    /// ...) and onion address it refers to.
    static func hiddenServiceDescriptorEvent(in reply: TorControlReply) -> (action: String, address: String)? {
        guard reply.isAsyncEvent, let line = reply.lines.first else { return nil }
        let parts = line.split(separator: " ")
        guard parts.count >= 3, parts[0] == "HS_DESC" else { return nil }
        return (String(parts[1]), String(parts[2]))
    }
}
