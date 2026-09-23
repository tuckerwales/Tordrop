import Foundation
import Combine

enum ShareStatus: Equatable {
    case idle
    /// `progress` is a 0...1 fraction when known (Tor bootstrap).
    case starting(message: String, progress: Double?)
    case sharing(onionURL: String)
    case stopping
    case error(String)

    /// A share is being set up or is live.
    var isActive: Bool {
        switch self {
        case .starting, .sharing: return true
        case .idle, .stopping, .error: return false
        }
    }
}

struct SharedFile: Identifiable, Equatable {
    /// Unique name the file is served under; also its identity.
    let name: String
    let url: URL
    let size: Int64
    /// Completed downloads.
    var downloads: Int = 0
    /// Downloads currently streaming.
    var activeTransfers: Int = 0

    var id: String { name }
}

struct LogLine: Identifiable, Equatable {
    let id: Int
    let text: String
}

@MainActor
final class ShareState: ObservableObject {
    static let shared = ShareState()

    @Published var status: ShareStatus = .idle
    @Published var files: [SharedFile] = []
    @Published private(set) var logLines: [LogLine] = []

    private var nextLogID = 0
    private static let maxLogLines = 500
    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var activeTransfers: Int { files.reduce(0) { $0 + $1.activeTransfers } }

    func log(_ line: String) {
        let timestamp = Self.timestampFormatter.string(from: Date())
        logLines.append(LogLine(id: nextLogID, text: "[\(timestamp)] \(line)"))
        nextLogID += 1
        if logLines.count > Self.maxLogLines {
            logLines.removeFirst(logLines.count - Self.maxLogLines)
        }
    }

    var logText: String { logLines.map(\.text).joined(separator: "\n") }

    func transferStarted(name: String) {
        guard let idx = files.firstIndex(where: { $0.name == name }) else { return }
        files[idx].activeTransfers += 1
    }

    func transferEnded(name: String, completed: Bool) {
        guard let idx = files.firstIndex(where: { $0.name == name }) else { return }
        files[idx].activeTransfers = max(0, files[idx].activeTransfers - 1)
        if completed { files[idx].downloads += 1 }
    }
}
