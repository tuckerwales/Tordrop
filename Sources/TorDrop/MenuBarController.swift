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
                let active: Bool
                switch status {
                case .sharing, .starting: active = true
                default: active = false
                }
                self?.setVisible(active)
            }
            .store(in: &cancellables)
    }

    private func setVisible(_ visible: Bool) {
        if visible {
            if statusItem == nil {
                installStatusItem()
            }
            updateIcon()
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
            drop.onDrop = { urls in
                Task { @MainActor in
                    await ShareManager.shared.start(files: urls)
                    self.showMainWindow()
                }
            }
            button.addSubview(drop)
        }
    }

    private func updateIcon() {
        guard let button = statusItem?.button else { return }
        button.image = Self.onionGlyph(filled: true)
        button.alphaValue = 1.0
        button.toolTip = "TorDrop — sharing"
    }

    /// Template glyph purpose-built for 18pt: a drop-zone circle with an
    /// upload arrow. Dashed circle when idle, solid when actively sharing.
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

    func shutdown() {
        Task { @MainActor in
            await ShareManager.shared.stop()
        }
    }
}
