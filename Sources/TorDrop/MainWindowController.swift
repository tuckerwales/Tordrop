import AppKit
import SwiftUI

@MainActor
final class MainWindowController: NSWindowController {
    private var hasShownWindow = false

    init() {
        let contentView = MainView(onQuit: { NSApp.terminate(nil) })
        let hostingController = NSHostingController(rootView: contentView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "TorDrop"
        window.setContentSize(NSSize(width: 720, height: 560))
        window.minSize = NSSize(width: 560, height: 500)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.titlebarAppearsTransparent = false
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) unused") }

    func show() {
        guard let window else { return }
        showWindow(nil)
        if !hasShownWindow {
            window.center()
            hasShownWindow = true
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
