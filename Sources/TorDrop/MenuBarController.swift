import AppKit
import SwiftUI
import Combine

@MainActor
final class MenuBarController: NSObject {
    private var statusItem: NSStatusItem?
    private let showMainWindow: () -> Void
    private var cancellables = Set<AnyCancellable>()

    init(showMainWindow: @escaping () -> Void) {
        self.showMainWindow = showMainWindow
        super.init()

        ShareState.shared.$status
            .receive(on: RunLoop.main)
            .sink { [weak self] status in
                self?.update(for: status)
            }
            .store(in: &cancellables)
    }

    private func update(for status: ShareStatus) {
        if status.isActive {
            if statusItem == nil {
                installStatusItem()
            }
            updateIcon(for: status)
        } else if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
    }

    private func installStatusItem() {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.statusItem = statusItem
        if let button = statusItem.button {
            let drop = MenuBarDropView(frame: button.bounds)
            drop.autoresizingMask = [.width, .height]
            drop.onClick = { [weak self] in self?.showMainWindow() }
            drop.onRightClick = { [weak self] in self?.showMenu() }
            drop.onDrop = { [weak self] urls in
                // Adds to the live share, keeping its address.
                ShareManager.shared.share(urls)
                self?.showMainWindow()
            }
            button.addSubview(drop)
        }
    }

    private func updateIcon(for status: ShareStatus) {
        guard let button = statusItem?.button else { return }
        let live: Bool
        if case .sharing = status { live = true } else { live = false }
        button.image = Self.onionGlyph(filled: live)
        button.alphaValue = 1.0
        button.toolTip = live
            ? "TorDrop: sharing. Drop files here to add them, right-click for options."
            : "TorDrop: connecting…"
    }

    private func showMenu() {
        guard let button = statusItem?.button else { return }
        let menu = NSMenu()

        let show = NSMenuItem(title: "Show TorDrop", action: #selector(showWindowAction), keyEquivalent: "")
        show.target = self
        menu.addItem(show)

        if case .sharing(let url) = ShareState.shared.status {
            let copy = NSMenuItem(title: "Copy Address", action: #selector(copyAddressAction), keyEquivalent: "")
            copy.target = self
            copy.representedObject = url
            menu.addItem(copy)
        }

        menu.addItem(.separator())
        let isStarting: Bool
        if case .starting = ShareState.shared.status { isStarting = true } else { isStarting = false }
        let stop = NSMenuItem(title: isStarting ? "Cancel" : "Stop Sharing",
                              action: #selector(stopAction), keyEquivalent: "")
        stop.target = self
        menu.addItem(stop)

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    @objc private func showWindowAction() { showMainWindow() }

    @objc private func copyAddressAction(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
    }

    @objc private func stopAction() { ShareManager.shared.stop() }

    /// Template glyph purpose-built for 18pt: a drop-zone circle with an
    /// upload arrow. Dashed circle while connecting, solid when live.
    private static func onionGlyph(filled active: Bool) -> NSImage {
        let canvas: CGFloat = 22
        let image = NSImage(size: NSSize(width: canvas, height: canvas), flipped: false) { rect in
            let inset: CGFloat = 2.5
            let w = rect.width - inset * 2
            let h = rect.height - inset * 2
            let ox = rect.minX + inset
            let oy = rect.minY + inset
            let cx = ox + w / 2
            let cy = oy + h / 2
            let lw: CGFloat = active ? 1.6 : 1.3

            NSColor.black.setStroke()

            // Drop-zone circle
            let circle = NSBezierPath(ovalIn: NSRect(
                x: ox, y: oy, width: w, height: h
            ))
            circle.lineWidth = lw
            if !active {
                circle.setLineDash([2.2, 1.6], count: 2, phase: 0)
            }
            circle.stroke()

            // Upload arrow (vertical shaft + chevron)
            let shaftLen: CGFloat = h * 0.40
            let shaftBottom = cy - shaftLen * 0.48
            let shaftTop    = cy + shaftLen * 0.52
            let chevronHalfW: CGFloat = w * 0.16
            let chevronBaseY = shaftTop - h * 0.14

            let shaft = NSBezierPath()
            shaft.move(to: NSPoint(x: cx, y: shaftBottom))
            shaft.line(to: NSPoint(x: cx, y: shaftTop))
            shaft.lineWidth = lw
            shaft.lineCapStyle = .round
            shaft.stroke()

            let chevron = NSBezierPath()
            chevron.move(to: NSPoint(x: cx - chevronHalfW, y: chevronBaseY))
            chevron.line(to: NSPoint(x: cx, y: shaftTop))
            chevron.line(to: NSPoint(x: cx + chevronHalfW, y: chevronBaseY))
            chevron.lineWidth = lw
            chevron.lineCapStyle = .round
            chevron.lineJoinStyle = .round
            chevron.stroke()

            return true
        }
        image.isTemplate = true
        return image
    }
}
