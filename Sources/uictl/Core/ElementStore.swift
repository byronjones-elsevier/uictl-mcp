import ApplicationServices

/// Maps synthetic element ids (handed out by `elements`/`screenshot --annotate`)
/// back to the live AXUIElement they were derived from, so a later `click
/// --element <id>` or `type --element <id>` doesn't need to re-walk the tree.
/// The daemon serves one request at a time, so this needs no locking.
/// Entries are scoped to a window and replaced wholesale each time that
/// window's elements are re-listed, since AX trees change as the UI updates.
final class ElementStore {
    static let shared = ElementStore()

    private var elementsByID: [String: AXUIElement] = [:]
    private var counterByWindow: [CGWindowID: Int] = [:]

    private init() {}

    func reset(windowID: CGWindowID) {
        counterByWindow[windowID] = 0
        elementsByID = elementsByID.filter { !$0.key.hasPrefix("\(windowID)-") }
    }

    func register(windowID: CGWindowID, element: AXUIElement) -> String {
        let next = (counterByWindow[windowID] ?? 0) + 1
        counterByWindow[windowID] = next
        let id = "\(windowID)-\(next)"
        elementsByID[id] = element
        return id
    }

    func lookup(_ id: String) -> AXUIElement? {
        elementsByID[id]
    }
}
