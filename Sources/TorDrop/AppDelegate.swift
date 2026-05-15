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

    func applicationWillTerminate(_ notification: Notification) {
        menuBarController?.shutdown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "Quit TorDrop",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        NSApp.mainMenu = mainMenu
    }
}
