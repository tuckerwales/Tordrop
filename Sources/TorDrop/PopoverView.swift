import SwiftUI
import AppKit

private enum Palette {
    static let accent = Color(red: 0.55, green: 0.36, blue: 0.96)
    static let accentSoft = Color(red: 0.55, green: 0.36, blue: 0.96).opacity(0.16)
    static let good = Color(red: 0.22, green: 0.78, blue: 0.45)
    static let danger = Color(red: 0.95, green: 0.37, blue: 0.42)
}

struct PopoverView: View {
    @ObservedObject private var state = ShareState.shared
    @State private var showingLog = false
    @State private var copied = false
    let onQuit: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            content
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            Spacer(minLength: 0)
            if showingLog { logPanel }
            footer
        }
        .frame(width: 400, height: 520)
        .animation(.easeInOut(duration: 0.18), value: state.status)
        .animation(.easeInOut(duration: 0.18), value: showingLog)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Text("TorDrop")
                .font(.system(size: 15, weight: .semibold))
            statusPill
            Spacer()
            Button(action: onQuit) {
                Image(systemName: "power")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Quit TorDrop")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
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
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
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
        VStack(spacing: 14) {
            VStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(Palette.accentSoft)
                        .frame(width: 54, height: 54)
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(Palette.accent)
                        .symbolRenderingMode(.hierarchical)
                }
                VStack(spacing: 2) {
                    Text("Share files over Tor")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Drop files onto the menu bar icon,\nor choose from your Mac.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)

            Button {
                pickFiles()
            } label: {
                Label("Choose Files…", systemImage: "folder")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(Palette.accent)

            Text("Files stay on your Mac. Only someone with the generated URL can reach them — routed through Tor, no servers in between.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 4)
        }
    }

    // MARK: Starting — progress state

    private func startingContent(_ msg: String) -> some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .stroke(Palette.accentSoft, lineWidth: 3)
                    .frame(width: 72, height: 72)
                Circle()
                    .trim(from: 0, to: 0.35)
                    .stroke(Palette.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .frame(width: 72, height: 72)
                    .rotationEffect(.degrees(spin))
                    .onAppear {
                        withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) {
                            spin = 360
                        }
                    }
                Image(systemName: "network")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(Palette.accent)
            }
            Text(msg)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text("Bootstrapping a fresh circuit can take a few seconds the first time.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    @State private var spin: Double = 0

    // MARK: Sharing — the hero state

    private func sharingContent(_ url: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            hero(url: url)
            filesSection
            Text("Recipient needs [Tor Browser](https://www.torproject.org/download/)")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .tint(Palette.accent)
        }
    }

    private func hero(url: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            QRCodeView(value: url, size: 108, tint: Palette.accent)

            VStack(alignment: .leading, spacing: 8) {
                Text("Share this address")
                    .font(.system(size: 10, weight: .semibold))
                    .kerning(0.6)
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)

                Text(url)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(4)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .foregroundStyle(.primary)

                HStack(spacing: 6) {
                    Button {
                        copy(url)
                    } label: {
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11, weight: .medium))
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.accent)

                    Button {
                        openInBrowser(url)
                    } label: {
                        Image(systemName: "arrow.up.forward.app")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                    .help("Open in default browser")
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Palette.accentSoft)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Palette.accent.opacity(0.25), lineWidth: 1)
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
            .frame(maxHeight: 112)
        }
    }

    private var summaryLine: String {
        let count = state.files.count
        let total = state.files.reduce(Int64(0)) { $0 + $1.size }
        let bytes = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
        return count == 1 ? "1 file · \(bytes)" : "\(count) files · \(bytes)"
    }

    // MARK: Footer

    private var footer: some View {
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

            if isActive {
                Button(role: .destructive) {
                    Task { await ShareManager.shared.stop() }
                } label: {
                    Label("Stop Sharing", systemImage: "stop.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 8)
                }
                .controlSize(.regular)
                .buttonStyle(.borderedProminent)
                .tint(Palette.danger)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
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


