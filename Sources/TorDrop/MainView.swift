import SwiftUI
import AppKit
import UniformTypeIdentifiers

private enum Palette {
    static let accent = Color(red: 0.55, green: 0.36, blue: 0.96)
    static let accentSoft = Color(red: 0.55, green: 0.36, blue: 0.96).opacity(0.16)
    static let panel = Color.primary.opacity(0.045)
    static let panelStroke = Color.primary.opacity(0.09)
    static let good = Color(red: 0.22, green: 0.78, blue: 0.45)
    static let danger = Color(red: 0.95, green: 0.37, blue: 0.42)
}

struct MainView: View {
    @ObservedObject private var state = ShareState.shared
    @State private var showingLog = false
    @State private var copied = false
    @State private var isDropTarget = false
    @State private var confirmingStop = false
    let onQuit: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            topBar
            content
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if showingLog { logPanel }
            bottomBar
        }
        .frame(minWidth: 520, idealWidth: 720, minHeight: 500, idealHeight: 560)
        .overlay(sharingDropHighlight)
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTarget, perform: handleDrop)
        .alert("Stop sharing?", isPresented: $confirmingStop) {
            Button("Stop Sharing", role: .destructive) { ShareManager.shared.stop() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(state.activeTransfers == 1
                 ? "A download is still in progress. Stopping now will cut it off."
                 : "\(state.activeTransfers) downloads are still in progress. Stopping now will cut them off.")
        }
        .animation(.easeInOut(duration: 0.18), value: state.status)
        .animation(.easeInOut(duration: 0.18), value: showingLog)
        .animation(.easeInOut(duration: 0.12), value: isDropTarget)
    }

    // MARK: Chrome

    private var topBar: some View {
        HStack(spacing: 12) {
            if isActive || isError {
                statusPill
            }
            Spacer()
            if isActive {
                Button(role: .destructive) {
                    requestStop()
                } label: {
                    Label(isStarting ? "Cancel" : "Stop Sharing", systemImage: "stop.fill")
                        .font(.system(size: 12, weight: .semibold))
                }
                .keyboardShortcut(".", modifiers: .command)
                .controlSize(.regular)
                .buttonStyle(.borderedProminent)
                .tint(Palette.danger)
            }
        }
        .padding(.horizontal, 28)
        .frame(height: isActive || isError ? 52 : 1)
        .background(.bar)
        .overlay(Divider().opacity(0.35), alignment: .bottom)
    }

    private var statusPill: some View {
        let (dot, label): (Color, String) = {
            switch state.status {
            case .idle:              return (.gray.opacity(0.6), "Idle")
            case .starting:          return (Palette.accent, "Connecting")
            case .sharing:           return (Palette.good, "Live")
            case .stopping:          return (.gray.opacity(0.6), "Stopping")
            case .error:             return (Palette.danger, "Error")
            }
        }()
        return HStack(spacing: 5) {
            Circle().fill(dot).frame(width: 6, height: 6)
                .overlay(Circle().stroke(dot.opacity(0.35), lineWidth: 3).blur(radius: 2))
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule(style: .continuous).fill(.quaternary.opacity(0.5))
        )
    }

    // MARK: Content (routes to the active state)

    @ViewBuilder
    private var content: some View {
        switch state.status {
        case .idle:
            idleContent
        case .starting(let msg, let progress):
            startingContent(msg, progress: progress)
        case .sharing(let url):
            sharingContent(url)
        case .stopping:
            startingContent("Stopping…", progress: nil)
        case .error(let msg):
            VStack(alignment: .leading, spacing: 12) {
                errorBanner(msg)
                idleContent
            }
        }
    }

    // MARK: Idle

    private var idleContent: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 0)

            VStack(spacing: 8) {
                Text("Share files over Tor")
                    .font(.system(size: 28, weight: .semibold))
                Text("Drop files or folders into this window, or choose them from your Mac.")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 10)

            VStack(spacing: 18) {
                ZStack {
                    Circle()
                        .fill(Palette.accentSoft)
                        .frame(width: 76, height: 76)
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 42))
                        .foregroundStyle(Palette.accent)
                        .symbolRenderingMode(.hierarchical)
                }

                Button {
                    FilePicker.chooseFilesToShare()
                } label: {
                    Label("Choose Files…", systemImage: "folder")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 220)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .tint(Palette.accent)
            }
            .frame(maxWidth: .infinity, minHeight: 250)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isDropTarget ? Palette.accentSoft : Color.primary.opacity(0.035))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(
                        Palette.accent.opacity(isDropTarget ? 0.75 : 0.32),
                        style: StrokeStyle(lineWidth: 1.5, dash: [7, 5])
                    )
            )

            Text("Files stay on your Mac. Only someone with the generated URL can reach them — routed through Tor, no servers in between. Folders are shared as .zip archives.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: Starting — progress state

    private func startingContent(_ msg: String, progress: Double?) -> some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .stroke(Palette.accentSoft, lineWidth: 3)
                    .frame(width: 92, height: 92)
                if let progress {
                    Circle()
                        .trim(from: 0, to: max(0.02, progress))
                        .stroke(Palette.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .frame(width: 92, height: 92)
                        .rotationEffect(.degrees(-90))
                        .animation(.easeInOut(duration: 0.3), value: progress)
                } else {
                    TimelineView(.animation) { context in
                        let period = 1.6
                        let phase = context.date.timeIntervalSinceReferenceDate
                            .truncatingRemainder(dividingBy: period) / period
                        Circle()
                            .trim(from: 0, to: 0.35)
                            .stroke(Palette.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .frame(width: 92, height: 92)
                            .rotationEffect(.degrees(phase * 360))
                    }
                }
                Image(systemName: "network")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(Palette.accent)
            }
            Text("Preparing your share")
                .font(.system(size: 24, weight: .semibold))
            Text(msg)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("Bootstrapping a fresh circuit can take a few seconds the first time.")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 70)
    }

    // MARK: Sharing — the hero state

    private func sharingContent(_ url: String) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Share is live")
                    .font(.system(size: 28, weight: .semibold))
                Text("Send this address to the recipient. They will need [Tor Browser](https://www.torproject.org/download/) to open it.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .tint(Palette.accent)
            }
            hero(url: url)
            filesSection
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func hero(url: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            QRCodeView(value: url, size: 132, tint: Palette.accent)

            VStack(alignment: .leading, spacing: 10) {
                Text("Share this address")
                    .font(.system(size: 11, weight: .semibold))
                    .kerning(0.6)
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)

                Text(url)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(4)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .foregroundStyle(.primary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.black.opacity(0.12))
                    )

                HStack(spacing: 8) {
                    Button {
                        copy(url)
                    } label: {
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 12, weight: .medium))
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.regular)
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.accent)

                    Button {
                        openInBrowser(url)
                    } label: {
                        Label("Open", systemImage: "arrow.up.forward.app")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .controlSize(.regular)
                    .buttonStyle(.bordered)
                    .help(Self.torBrowserURL != nil ? "Open in Tor Browser" : "Open in default browser (needs Tor to load)")
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Palette.panel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Palette.panelStroke, lineWidth: 1)
        )
    }

    private var filesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Sharing")
                    .font(.system(size: 10, weight: .semibold))
                    .kerning(0.6)
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(summaryLine)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Button {
                    FilePicker.chooseFilesToShare()
                } label: {
                    Label("Add Files…", systemImage: "plus")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Palette.accent)
                .help("Add more files to this share. The address stays the same.")
            }
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(state.files) { file in
                        FileRow(file: file) {
                            ShareManager.shared.remove(file)
                        }
                    }
                    if state.files.isEmpty {
                        Text("No files in this share. Add some, or drop them here.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                }
            }
            .frame(maxHeight: 170)
        }
    }

    private var summaryLine: String {
        let count = state.files.count
        let total = state.files.reduce(Int64(0)) { $0 + $1.size }
        let bytes = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
        var line = count == 1 ? "1 file · \(bytes)" : "\(count) files · \(bytes)"
        let active = state.activeTransfers
        if active > 0 {
            line += active == 1 ? " · 1 download in progress" : " · \(active) downloads in progress"
        }
        return line
    }

    // MARK: Footer

    private var bottomBar: some View {
        HStack(spacing: 8) {
            Button {
                showingLog.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: showingLog ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                    Text("Log")
                        .font(.system(size: 11))
                }
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)

            Spacer()

            if showingLog {
                Button("Copy Log") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(state.logText, forType: .string)
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .disabled(state.logLines.isEmpty)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 12)
        .background(.bar)
        .overlay(Divider().opacity(0.4), alignment: .top)
    }

    private var logPanel: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(state.logLines) { line in
                        Text(line.text)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .textSelection(.enabled)
                            .help(line.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(line.id)
                    }
                }
                .padding(10)
            }
            .frame(height: 110)
            .background(Color.black.opacity(0.18))
            // Keyed on the last line's id, not the count: once the log is
            // full the count stops changing but new lines keep arriving.
            .onChange(of: state.logLines.last?.id) { id in
                if let id { proxy.scrollTo(id, anchor: .bottom) }
            }
            .onAppear {
                if let id = state.logLines.last?.id { proxy.scrollTo(id, anchor: .bottom) }
            }
        }
    }

    // MARK: Error

    private func errorBanner(_ msg: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Palette.danger)
            Text(msg)
                .font(.system(size: 11))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.danger.opacity(0.1))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Palette.danger.opacity(0.3), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    // MARK: Helpers

    private var isActive: Bool { state.status.isActive }

    private var isStarting: Bool {
        if case .starting = state.status { return true }
        return false
    }

    private var isSharing: Bool {
        if case .sharing = state.status { return true }
        return false
    }

    private var isError: Bool {
        if case .error = state.status { return true }
        return false
    }

    /// Outline shown when files are dragged over a live share. The idle
    /// screen has its own drop zone.
    @ViewBuilder
    private var sharingDropHighlight: some View {
        if isSharing && isDropTarget {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Palette.accent.opacity(0.75), style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                .background(Palette.accentSoft.opacity(0.4))
                .padding(6)
                .allowsHitTesting(false)
        }
    }

    private func requestStop() {
        if isSharing && state.activeTransfers > 0 {
            confirmingStop = true
        } else {
            ShareManager.shared.stop()
        }
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        withAnimation { copied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            withAnimation { copied = false }
        }
    }

    private static var torBrowserURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "org.torproject.torbrowser")
    }

    /// Opens the address in Tor Browser when it is installed; other browsers
    /// cannot resolve .onion addresses.
    private func openInBrowser(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        if let torBrowser = Self.torBrowserURL {
            NSWorkspace.shared.open([url], withApplicationAt: torBrowser,
                                    configuration: NSWorkspace.OpenConfiguration(),
                                    completionHandler: nil)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        switch state.status {
        case .idle, .error, .sharing: break
        case .starting, .stopping: return false
        }
        let fileProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        guard !fileProviders.isEmpty else { return false }

        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [(index: Int, url: URL)] = []

        for (index, provider) in fileProviders.enumerated() {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                let url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let nsURL = item as? NSURL {
                    url = nsURL as URL
                } else {
                    url = nil
                }
                guard let url, url.isFileURL else { return }
                lock.lock()
                urls.append((index, url))
                lock.unlock()
            }
        }

        group.notify(queue: .main) {
            // Callbacks finish in any order; keep the order of the drop.
            let ordered = urls.sorted { $0.index < $1.index }.map { $0.url }
            ShareManager.shared.share(ordered)
        }
        return true
    }
}

/// Presents the open panel and shares (or adds) the chosen files.
enum FilePicker {
    @MainActor
    static func chooseFilesToShare() {
        let adding: Bool
        switch ShareState.shared.status {
        case .sharing: adding = true
        case .idle, .error: adding = false
        case .starting, .stopping: return
        }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.prompt = adding ? "Add" : "Share"
        panel.message = adding
            ? "Choose files or folders to add to this share"
            : "Choose files or folders to share over Tor. Folders are shared as .zip archives."
        if panel.runModal() == .OK {
            ShareManager.shared.share(panel.urls)
        }
    }
}

// MARK: - File row

private struct FileRow: View {
    let file: SharedFile
    let onRemove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Palette.accentSoft)
                    .frame(width: 28, height: 28)
                Image(systemName: Self.icon(for: file.url))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Palette.accent)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(file.name)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if file.activeTransfers > 0 {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.mini)
                    Text(file.activeTransfers == 1 ? "Sending" : "Sending ×\(file.activeTransfers)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Palette.accent)
                }
                .help("A recipient is downloading this file")
            }
            if file.downloads > 0 {
                Text("\(file.downloads)×")
                    .font(.system(size: 10, weight: .semibold))
                    .monospacedDigit()
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Palette.good.opacity(0.18)))
                    .foregroundStyle(Palette.good)
                    .help(file.downloads == 1 ? "Downloaded once" : "Downloaded \(file.downloads) times")
            } else if file.activeTransfers == 0 {
                Text("—")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .help("Not downloaded yet")
            }
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .opacity(hovering ? 1 : 0.35)
            .help("Stop sharing this file")
        }
        .onHover { hovering = $0 }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }

    private static func icon(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg", "png", "gif", "heic", "webp", "tiff":
            return "photo.fill"
        case "mp4", "mov", "mkv", "avi", "webm":
            return "film.fill"
        case "mp3", "wav", "m4a", "flac", "aac":
            return "music.note"
        case "pdf":
            return "doc.richtext.fill"
        case "zip", "tar", "gz", "7z", "bz2":
            return "archivebox.fill"
        case "txt", "md", "rtf":
            return "doc.text.fill"
        case "key", "pages", "numbers":
            return "doc.fill"
        default:
            return "doc.fill"
        }
    }
}
