import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindowController: MainWindowController?
    private var menuBarController: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()

        let mainWindowController = MainWindowController()
        self.mainWindowController = mainWindowController
        self.menuBarController = MenuBarController(
            showMainWindow: { [weak mainWindowController] in
                mainWindowController?.show()
            }
        )
        mainWindowController.show()
    }

    /// Files dropped on the Dock icon or opened with "Open With → TorDrop".
    func application(_ application: NSApplication, open urls: [URL]) {
        ShareManager.shared.share(urls.filter(\.isFileURL))
        mainWindowController?.show()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { mainWindowController?.show() }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard ShareState.shared.status.isActive else { return .terminateNow }

        let alert = NSAlert()
        alert.messageText = "Quit TorDrop and stop sharing?"
        let transfers = ShareState.shared.activeTransfers
        alert.informativeText = transfers > 0
            ? "\(transfers == 1 ? "A download is" : "\(transfers) downloads are") still in progress. Quitting takes the onion address offline and cuts off recipients."
            : "Quitting takes the onion address offline. Recipients will no longer be able to download your files."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Synchronous: a Task would never get to run before the process exits.
        ShareManager.shared.stop(waitUntilDone: true)
    }

    /// Closing the window while a share is live keeps it running (the menu
    /// bar icon and Dock icon bring the window back).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !ShareState.shared.status.isActive
    }

    // MARK: Menus

    @objc private func chooseFiles(_ sender: Any?) {
        mainWindowController?.show()
        FilePicker.chooseFilesToShare()
    }

    @objc private func showMainWindow(_ sender: Any?) {
        mainWindowController?.show()
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About TorDrop",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide TorDrop", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others",
                                         action: #selector(NSApplication.hideOtherApplications(_:)),
                                         keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Quit TorDrop",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        addSubmenu(appMenu, to: mainMenu)

        // File menu
        let fileMenu = NSMenu(title: "File")
        let choose = fileMenu.addItem(withTitle: "Share Files…", action: #selector(chooseFiles(_:)),
                                      keyEquivalent: "o")
        choose.target = self
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)),
                         keyEquivalent: "w")
        addSubmenu(fileMenu, to: mainMenu)

        // Edit menu, so Copy / Select All work in selectable text.
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        addSubmenu(editMenu, to: mainMenu)

        // Window menu
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)),
                           keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        let show = windowMenu.addItem(withTitle: "TorDrop", action: #selector(showMainWindow(_:)),
                                      keyEquivalent: "0")
        show.target = self
        addSubmenu(windowMenu, to: mainMenu)
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    private func addSubmenu(_ submenu: NSMenu, to menu: NSMenu) {
        let item = NSMenuItem()
        item.submenu = submenu
        menu.addItem(item)
    }
}
