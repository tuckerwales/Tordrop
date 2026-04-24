import AppKit

/// Transparent overlay added on top of the NSStatusBarButton so the menu
/// bar icon can accept file drops. Forwards click events to a supplied
/// handler since the subview would otherwise swallow them.
final class MenuBarDropView: NSView {
    var onClick: () -> Void = {}
    var onDrop: ([URL]) -> Void = { _ in }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) unused") }

    // MARK: Clicks

    override func mouseDown(with event: NSEvent) {
        onClick()
    }

    // MARK: Drag

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        readURLs(from: sender.draggingPasteboard).isEmpty ? [] : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        readURLs(from: sender.draggingPasteboard).isEmpty ? [] : .copy
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        !readURLs(from: sender.draggingPasteboard).isEmpty
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = readURLs(from: sender.draggingPasteboard)
        guard !urls.isEmpty else { return false }
        onDrop(urls)
        return true
    }

    private func readURLs(from pasteboard: NSPasteboard) -> [URL] {
        let opts: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true
        ]
        return (pasteboard.readObjects(forClasses: [NSURL.self], options: opts)
                as? [URL]) ?? []
    }
}
