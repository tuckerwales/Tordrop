import Foundation

/// Orchestrates the FileServer + TorController lifecycle. Exposes a single
/// `start(files:)` / `stop()` API that the UI binds against.
@MainActor
final class ShareManager {
    static let shared = ShareManager()

    private var fileServer: FileServer?
    private var torController: TorController?

    func start(files: [URL]) async {
        guard !files.isEmpty else { return }
        let state = ShareState.shared

        state.status = .starting(message: "Starting HTTP server…")
        state.files = files.compactMap { url in
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path))
                .flatMap { $0[.size] as? NSNumber }?
                .int64Value ?? 0
            return SharedFile(url: url, size: size, downloads: 0)
        }

        do {
            let server = try FileServer(
                files: files,
                onDownload: { [weak self] url in
                    Task { @MainActor in self?.handleDownload(url: url) }
                },
                logHandler: { msg in
                    Task { @MainActor in state.log(msg) }
                }
            )
            try server.start()
            self.fileServer = server

            state.status = .starting(message: "Connecting to the Tor network…")
            let tor = TorController(logHandler: { msg in
                Task { @MainActor in state.log(msg) }
            })
            self.torController = tor
            let onion = try await tor.start(forwardingToLocalPort: server.port)

            let fullURL = "http://\(onion)/\(server.urlSlug)/"
            state.status = .sharing(onionURL: fullURL)
            state.log("Ready: \(fullURL)")
        } catch {
            state.status = .error(error.localizedDescription)
            state.log("Error: \(error.localizedDescription)")
            await stop()
        }
    }

    func stop() async {
        ShareState.shared.status = .stopping
        ShareState.shared.log("Stopping…")
        torController?.stop()
        fileServer?.stop()
        torController = nil
        fileServer = nil
        ShareState.shared.files = []
        ShareState.shared.status = .idle
        ShareState.shared.log("Stopped.")
    }

    private func handleDownload(url: URL) {
        ShareState.shared.incrementDownload(for: url)
    }
}
