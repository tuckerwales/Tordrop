import AppKit
import SwiftUI
import Combine

@MainActor
final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private var cancellables = Set<AnyCancellable>()

    override init() {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.popover = NSPopover()
        super.init()

        popover.behavior = .transient
        popover.contentSize = NSSize(width: 400, height: 520)
        popover.contentViewController = NSHostingController(
            rootView: PopoverView(onQuit: { NSApp.terminate(nil) })
        )

        if let button = statusItem.button {
            let drop = MenuBarDropView(frame: button.bounds)
            drop.autoresizingMask = [.width, .height]
            drop.onClick = { [weak self] in self?.togglePopover(nil) }
            drop.onDrop = { urls in
                Task { @MainActor in
                    await ShareManager.shared.start(files: urls)
                }
            }
            button.addSubview(drop)
        }
        updateIcon(active: false)

        ShareState.shared.$status
            .receive(on: RunLoop.main)
            .sink { [weak self] status in
                let active: Bool
                switch status {
                case .sharing, .starting: active = true
                default: active = false
                }
                self?.updateIcon(active: active)
            }
            .store(in: &cancellables)
    }

    private func updateIcon(active: Bool) {
        guard let button = statusItem.button else { return }
        button.image = Self.onionGlyph(filled: active)
        button.alphaValue = 1.0
        button.toolTip = active ? "TorDrop — sharing" : "TorDrop"
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

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func shutdown() {
        Task { @MainActor in
            await ShareManager.shared.stop()
        }
    }
}
