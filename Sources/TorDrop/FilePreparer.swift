import Foundation

/// Turns what the user picked or dropped into plain files the server can
/// stream: folders (and packages such as .app bundles) are compressed into
/// zip archives inside a private working directory.
enum FilePreparer {
    enum PrepareError: LocalizedError {
        case unreadable(String)
        case compressionFailed(String, Int32)

        var errorDescription: String? {
            switch self {
            case .unreadable(let name):
                return "“\(name)” cannot be read. Check that it still exists and that TorDrop has permission to access it."
            case .compressionFailed(let name, let code):
                return "Could not compress “\(name)” (ditto exited with code \(code))."
            }
        }
    }

    /// Returns one shareable file URL per input, preserving order and
    /// dropping duplicates. Directories are zipped into `workingDirectory`.
    /// `progress` is called on the caller's actor before each folder is
    /// compressed.
    @MainActor
    static func prepare(_ urls: [URL], workingDirectory: URL,
                        progress: (String) -> Void) async throws -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []
        for url in urls {
            let original = url.standardizedFileURL
            let resolved = original.resolvingSymlinksInPath()
            guard seen.insert(resolved.path).inserted else { continue }

            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory),
                  FileManager.default.isReadableFile(atPath: resolved.path) else {
                throw PrepareError.unreadable(url.lastPathComponent)
            }
            if isDirectory.boolValue {
                progress("Compressing “\(original.lastPathComponent)”…")
                result.append(try await zip(directory: resolved, named: original.lastPathComponent,
                                            into: workingDirectory))
            } else {
                // Keep the name the user sees; reads follow the link anyway.
                result.append(original)
            }
        }
        return result
    }

    private static func zip(directory: URL, named name: String,
                            into workingDirectory: URL) async throws -> URL {
        // A per-archive subdirectory keeps the archive's name equal to the
        // folder's name even if two folders share one.
        let outDir = workingDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let archive = outDir.appendingPathComponent(name + ".zip")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", directory.path, archive.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
        try Task.checkCancellation()
        guard status == 0 else {
            throw PrepareError.compressionFailed(name, status)
        }
        return archive
    }
}
