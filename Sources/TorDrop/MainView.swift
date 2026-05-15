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
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTarget, perform: handleDrop)
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
                    Task { await ShareManager.shared.stop() }
                } label: {
                    Label("Stop Sharing", systemImage: "stop.fill")
                        .font(.system(size: 12, weight: .semibold))
                }
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
        case .starting(let msg):
            startingContent(msg)
        case .sharing(let url):
            sharingContent(url)
        case .stopping:
            startingContent("Stopping…")
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
                Text("Drop files into this window or choose them from your Mac.")
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
                    pickFiles()
                } label: {
                    Label("Choose Files...", systemImage: "folder")
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

            Text("Files stay on your Mac. Only someone with the generated URL can reach them — routed through Tor, no servers in between.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: Starting — progress state

    private func startingContent(_ msg: String) -> some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .stroke(Palette.accentSoft, lineWidth: 3)
                    .frame(width: 92, height: 92)
                Circle()
                    .trim(from: 0, to: 0.35)
                    .stroke(Palette.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .frame(width: 92, height: 92)
                    .rotationEffect(.degrees(spin))
                    .onAppear {
                        withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) {
                            spin = 360
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
            Text("Bootstrapping a fresh circuit can take a few seconds the first time.")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 70)
    }

    @State private var spin: Double = 0

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
                    .help("Open in default browser")
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
            }
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(state.files) { file in
                        FileRow(file: file)
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
        return count == 1 ? "1 file · \(bytes)" : "\(count) files · \(bytes)"
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
                    ForEach(Array(state.logLines.enumerated()), id: \.offset) { idx, line in
                        Text(line)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(idx)
                    }
                }
                .padding(10)
            }
            .frame(height: 110)
            .background(Color.black.opacity(0.18))
            .onChange(of: state.logLines.count) { new in
                proxy.scrollTo(new - 1, anchor: .bottom)
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

    private var isActive: Bool {
        if case .sharing = state.status { return true }
        if case .starting = state.status { return true }
        return false
    }

    private var isError: Bool {
        if case .error = state.status { return true }
        return false
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = "Share"
        panel.message = "Choose one or more files to share over Tor"
        if panel.runModal() == .OK {
            Task { await ShareManager.shared.start(files: panel.urls) }
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

    private func openInBrowser(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        guard !fileProviders.isEmpty else { return false }

        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []

        for provider in fileProviders {
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
                urls.append(url)
                lock.unlock()
            }
        }

        group.notify(queue: .main) {
            guard !urls.isEmpty else { return }
            Task { await ShareManager.shared.start(files: urls) }
        }
        return true
    }
}

// MARK: - File row

private struct FileRow: View {
    let file: SharedFile

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
                Text(file.url.lastPathComponent)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if file.downloads > 0 {
                Text("\(file.downloads)×")
                    .font(.system(size: 10, weight: .semibold))
                    .monospacedDigit()
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Palette.good.opacity(0.18)))
                    .foregroundStyle(Palette.good)
            } else {
                Text("—")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
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
