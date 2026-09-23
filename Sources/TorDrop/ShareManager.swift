import Foundation

/// Orchestrates the FileServer + TorController lifecycle. The UI calls
/// `share(_:)` with whatever the user picked or dropped, and `stop()`.
@MainActor
final class ShareManager {
    static let shared = ShareManager()

    private var fileServer: FileServer?
    private var torController: TorController?
    private var startTask: Task<Void, Never>?
    private var workingDirectory: URL?
    private var activity: NSObjectProtocol?
    /// Bumped on every start and stop so a superseded start can tell that
    /// its results (or failures) no longer matter.
    private var generation = 0

    private var state: ShareState { .shared }

    /// Starts a new share, or adds the files to the current one if a share
    /// is already live (so the address stays the same).
    func share(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        switch state.status {
        case .sharing:
            Task { await add(urls) }
        case .starting:
            state.log("A share is still starting; add more files once it is live.")
        case .stopping:
            break
        case .idle, .error:
            start(urls)
        }
    }

    /// Stops everything. With `waitUntilDone`, blocks until tor has exited
    /// and temporary files are removed (used at app quit).
    func stop(waitUntilDone: Bool = false) {
        let wasActive = state.status.isActive
        generation += 1
        state.status = .stopping
        teardown(waitUntilDone: waitUntilDone)
        state.status = .idle
        if wasActive { state.log("Stopped.") }
    }

    func remove(_ file: SharedFile) {
        fileServer?.remove(name: file.name)
        state.files.removeAll { $0.name == file.name }
        state.log("Removed \(file.name) from the share.")
    }

    // MARK: Start

    private func start(_ urls: [URL]) {
        generation += 1
        let gen = generation
        state.files = []
        state.status = .starting(message: "Preparing files…", progress: nil)
        beginActivity()
        startTask = Task { await run(urls, generation: gen) }
    }

    private func run(_ urls: [URL], generation gen: Int) async {
        do {
            let workingDirectory = try makeWorkingDirectory()
            let files = try await FilePreparer.prepare(urls, workingDirectory: workingDirectory) { message in
                self.updateProgress(message, nil, generation: gen)
            }
            try checkCurrent(gen)

            let server = try FileServer(
                // DispatchQueue.main (unlike Task {}) delivers in order, so
                // transfer start/end events and log lines never swap.
                onEvent: { [weak self] event in
                    DispatchQueue.main.async { self?.handle(event, generation: gen) }
                },
                logHandler: { msg in
                    DispatchQueue.main.async { ShareState.shared.log(msg) }
                }
            )
            fileServer = server
            let entries = try server.add(files: files)
            state.files = entries.map { SharedFile(name: $0.name, url: $0.url, size: $0.size) }

            updateProgress("Starting HTTP server…", nil, generation: gen)
            try await server.start()
            try checkCurrent(gen)

            updateProgress("Connecting to the Tor network…", nil, generation: gen)
            let tor = TorController(
                logHandler: { msg in
                    DispatchQueue.main.async { ShareState.shared.log(msg) }
                },
                progressHandler: { [weak self] message, progress in
                    DispatchQueue.main.async { self?.updateProgress(message, progress, generation: gen) }
                }
            )
            torController = tor
            let onion = try await tor.start(forwardingToLocalPort: server.port)
            try checkCurrent(gen)

            let fullURL = "http://\(onion)/\(server.urlSlug)/"
            state.status = .sharing(onionURL: fullURL)
            state.log("Ready: \(fullURL)")
        } catch {
            // A stop (or newer start) already cleaned up after this attempt.
            guard gen == generation, !(error is CancellationError) else { return }
            let message = error.localizedDescription
            teardown(waitUntilDone: false)
            state.status = .error(message)
            state.log("Error: \(message)")
        }
    }

    private func add(_ urls: [URL]) async {
        guard let server = fileServer, let workingDirectory else { return }
        let gen = generation
        do {
            let files = try await FilePreparer.prepare(urls, workingDirectory: workingDirectory) { message in
                ShareState.shared.log(message)
            }
            guard gen == generation else { return }
            let entries = try server.add(files: files)
            state.files += entries.map { SharedFile(name: $0.name, url: $0.url, size: $0.size) }
            for entry in entries { state.log("Added \(entry.name) to the share.") }
        } catch {
            state.log("Could not add files: \(error.localizedDescription)")
        }
    }

    // MARK: Helpers

    private func checkCurrent(_ gen: Int) throws {
        if gen != generation || Task.isCancelled { throw CancellationError() }
    }

    private func updateProgress(_ message: String, _ progress: Double?, generation gen: Int) {
        guard gen == generation, case .starting = state.status else { return }
        state.status = .starting(message: message, progress: progress)
    }

    private func handle(_ event: FileServer.Event, generation gen: Int) {
        guard gen == generation else { return }
        switch event {
        case .transferStarted(let name):
            state.transferStarted(name: name)
        case .transferEnded(let name, let completed):
            state.transferEnded(name: name, completed: completed)
        }
    }

    private func makeWorkingDirectory() throws -> URL {
        if let workingDirectory { return workingDirectory }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tordrop-files-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        workingDirectory = dir
        return dir
    }

    private func teardown(waitUntilDone: Bool) {
        startTask?.cancel()
        startTask = nil
        torController?.stop(waitUntilDone: waitUntilDone)
        torController = nil
        fileServer?.stop()
        fileServer = nil
        if let workingDirectory {
            try? FileManager.default.removeItem(at: workingDirectory)
            self.workingDirectory = nil
        }
        state.files = []
        endActivity()
    }

    /// Keeps the Mac from idle-sleeping (and App Nap from throttling the
    /// server) while a share is starting or live.
    private func beginActivity() {
        guard activity == nil else { return }
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Sharing files over Tor"
        )
    }

    private func endActivity() {
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }
}
