import AppKit

/// A brief, non-interactive on-screen reminder that uictl is actively driving
/// the UI, shown once per call. Rapid successive calls coalesce into the same
/// panel (its text and fade timer just reset) rather than stacking up toasts.
/// All methods must be called on the main thread.
final class ToastController {
    static let shared = ToastController()

    private var panel: NSPanel?
    private var label: NSTextField?
    private var hideTimer: Timer?

    private init() {}

    func show(for entry: ActivityEntry) {
        if panel == nil { makePanel() }
        guard let panel, let label else { return }

        label.stringValue = "\(entry.ok ? "🔴" : "⚠️") uictl: \(entry.command)"
        panel.layoutIfNeeded()
        positionNearMouse(panel)
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            self?.fadeOut()
        }
    }

    private func makePanel() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 34),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

        let background = NSVisualEffectView(frame: panel.contentView!.bounds)
        background.material = .popover
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 8
        background.autoresizingMask = [.width, .height]

        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        label.frame = background.bounds.insetBy(dx: 12, dy: 9)
        label.autoresizingMask = [.width, .height]

        background.addSubview(label)
        panel.contentView = background

        self.panel = panel
        self.label = label
    }

    private func positionNearMouse(_ panel: NSPanel) {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouseLocation) } ?? NSScreen.main
        guard let visibleFrame = screen?.visibleFrame else { return }
        let origin = NSPoint(x: visibleFrame.maxX - panel.frame.width - 20, y: visibleFrame.maxY - panel.frame.height - 20)
        panel.setFrameOrigin(origin)
    }

    private func fadeOut() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
    }
}
