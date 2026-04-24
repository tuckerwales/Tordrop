import Foundation
import Combine

enum ShareStatus: Equatable {
    case idle
    case starting(message: String)
    case sharing(onionURL: String)
    case stopping
    case error(String)
}

struct SharedFile: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let size: Int64
    var downloads: Int
}

@MainActor
final class ShareState: ObservableObject {
    static let shared = ShareState()

    @Published var status: ShareStatus = .idle
    @Published var files: [SharedFile] = []
    @Published var logLines: [String] = []

    func log(_ line: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        logLines.append("[\(timestamp)] \(line)")
        if logLines.count > 200 { logLines.removeFirst(logLines.count - 200) }
    }

    func incrementDownload(for fileURL: URL) {
        guard let idx = files.firstIndex(where: { $0.url == fileURL }) else { return }
        files[idx].downloads += 1
    }
}
