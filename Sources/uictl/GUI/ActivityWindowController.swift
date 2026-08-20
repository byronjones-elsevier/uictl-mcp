import AppKit
import UniformTypeIdentifiers

/// The on-screen window opened by `uictl log show`: a live "active/idle"
/// banner plus a scrollable table of every call the daemon has handled, with
/// a button to export the log as JSON — the same summarized/truncated/
/// redacted params and response text shown in the table, via
/// `ActivityLog.exportJSON` (see its doc comment for exactly what that
/// means). Reused across repeated `log show` calls rather than recreated.
/// All methods must be called on the main thread.
final class ActivityWindowController: NSWindowController {
    static let shared = ActivityWindowController()

    /// Columns whose value is often wider than the cell — clicking shows the
    /// full value in a popover, right-clicking offers to copy it.
    private static let expandableColumns: Set<String> = ["params", "response"]

    private let tableView = NSTableView()
    private let bannerLabel = NSTextField(labelWithString: "Idle")
    private var entries: [ActivityEntry] = ActivityLog.shared.snapshot()
    private var idleTimer: Timer?
    private var activePopover: NSPopover?

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 420),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "uictl Activity Log"
        window.center()
        super.init(window: window)
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError("not intended for storyboard/nib loading") }

    private func buildUI() {
        guard let contentView = window?.contentView else { return }
        let bounds = contentView.bounds

        bannerLabel.font = .boldSystemFont(ofSize: 13)
        bannerLabel.frame = NSRect(x: 14, y: bounds.height - 30, width: bounds.width - 150, height: 20)
        bannerLabel.autoresizingMask = [.width, .minYMargin]
        contentView.addSubview(bannerLabel)

        let exportButton = NSButton(title: "Export JSON…", target: self, action: #selector(exportTapped))
        exportButton.bezelStyle = .rounded
        exportButton.frame = NSRect(x: bounds.width - 140, y: bounds.height - 34, width: 126, height: 26)
        exportButton.autoresizingMask = [.minXMargin, .minYMargin]
        contentView.addSubview(exportButton)

        let columns: [(id: String, title: String, width: CGFloat)] = [
            ("time", "Time", 90),
            ("command", "Command", 130),
            ("ok", "OK", 34),
            ("duration", "ms", 50),
            ("params", "Params", 270),
            ("response", "Response", 270),
        ]
        for column in columns {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.id))
            tableColumn.title = column.title
            tableColumn.width = column.width
            tableView.addTableColumn(tableColumn)
        }
        tableView.dataSource = self
        tableView.delegate = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - 40))
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autoresizingMask = [.width, .height]
        contentView.addSubview(scrollView)
    }

    /// Appends a freshly-recorded entry and refreshes the banner/table.
    /// Called via `ActivityLog.shared.onRecord`, already on the main thread.
    func append(_ entry: ActivityEntry) {
        entries.append(entry)
        tableView.reloadData()
        if !entries.isEmpty { tableView.scrollRowToVisible(entries.count - 1) }

        bannerLabel.stringValue = "\(entry.ok ? "🟢" : "🔴") Active: \(entry.command)"
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
            self?.bannerLabel.stringValue = "Idle"
        }
    }

    @objc private func exportTapped() {
        let panel = NSSavePanel()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withYear, .withMonth, .withDay, .withTime, .withColonSeparatorInTime]
        let stamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = "uictl-activity-\(stamp).json"
        panel.allowedContentTypes = [.json]

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try ActivityLog.shared.exportJSON(to: url.path)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Export failed"
            alert.informativeText = "\(error)"
            alert.runModal()
        }
    }

    // MARK: - Expandable cell popover/copy

    @objc private func expandableCellClicked(_ sender: NSButton) {
        guard !sender.title.isEmpty else { return }
        showPopover(text: sender.title, anchor: sender)
    }

    @objc private func copyExpandableCell(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func showPopover(text: String, anchor: NSView) {
        activePopover?.close()

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 420, height: 240))
        textView.string = text
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .systemFont(ofSize: 12)
        textView.textContainerInset = NSSize(width: 8, height: 8)

        let scrollView = NSScrollView(frame: textView.frame)
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder

        let viewController = NSViewController()
        viewController.view = scrollView

        let popover = NSPopover()
        popover.contentViewController = viewController
        popover.contentSize = NSSize(width: 420, height: 240)
        popover.behavior = .transient
        activePopover = popover

        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
    }
}

extension ActivityWindowController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard entries.indices.contains(row), let columnID = tableColumn?.identifier.rawValue else { return nil }
        let entry = entries[row]
        let isExpandable = Self.expandableColumns.contains(columnID)

        let text: String
        switch columnID {
        case "time": text = DateFormatter.localizedString(from: entry.timestamp, dateStyle: .none, timeStyle: .medium)
        case "command": text = entry.command
        case "ok": text = entry.ok ? "✓" : "✗"
        case "duration": text = String(format: "%.0f", entry.durationMs)
        case "params": text = entry.paramsSummary
        case "response": text = entry.responseSummary
        default: text = ""
        }

        // Expandable columns use a borderless NSButton rather than a plain
        // NSTextField label: NSTableView's own click-to-select handling
        // appears to swallow clicks on non-interactive label fields before a
        // gesture recognizer or the `.menu` property ever sees them (only
        // discovered via real mouse testing — synthetic clicks didn't
        // reliably distinguish this). Buttons are real NSControls, so both
        // their target-action and `.menu` context menu are delivered
        // normally inside a table cell.
        if isExpandable {
            let identifier = NSUserInterfaceItemIdentifier("expandableCell")
            let button: NSButton
            if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSButton {
                button = reused
            } else {
                button = NSButton(title: "", target: self, action: #selector(expandableCellClicked(_:)))
                button.identifier = identifier
                button.bezelStyle = .inline
                button.isBordered = false
                button.alignment = .left
                button.font = .systemFont(ofSize: 11)
                button.contentTintColor = .labelColor
                (button.cell as? NSButtonCell)?.lineBreakMode = .byTruncatingTail

                let menu = NSMenu()
                let copyItem = NSMenuItem(title: "Copy", action: #selector(copyExpandableCell(_:)), keyEquivalent: "")
                copyItem.target = self
                menu.addItem(copyItem)
                button.menu = menu
            }
            button.title = text
            // The menu is built once above; only its representedObject (the
            // text to copy) needs refreshing on every reuse.
            button.menu?.items.first?.representedObject = text

            return button
        }

        let identifier = NSUserInterfaceItemIdentifier("cell")
        let field: NSTextField
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField {
            field = reused
        } else {
            field = NSTextField(labelWithString: "")
            field.identifier = identifier
            field.lineBreakMode = .byTruncatingTail
            field.font = .systemFont(ofSize: 11)
        }
        field.stringValue = text
        return field
    }
}
