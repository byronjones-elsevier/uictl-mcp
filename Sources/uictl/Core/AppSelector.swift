import AppKit

/// Resolves the `--app` selector accepted by most subcommands: a numeric pid,
/// a reverse-DNS bundle identifier, or a case-insensitive substring of the
/// app's display name.
enum AppSelector {
    /// Every running app matching `selector`. Pid/bundle-id selectors always
    /// resolve to at most one app; a name substring can match several running
    /// instances at once (e.g. a just-relaunched app briefly overlapping with
    /// its predecessor), and callers that want to act across all of them
    /// (`windows.list`) should use this instead of `resolve`.
    static func resolveAll(_ selector: String) throws -> [NSRunningApplication] {
        let apps = NSWorkspace.shared.runningApplications

        if let pid = Int32(selector), let match = apps.first(where: { $0.processIdentifier == pid }) {
            return [match]
        }

        if selector.contains("."), !selector.contains(" "),
           let match = apps.first(where: { $0.bundleIdentifier?.caseInsensitiveCompare(selector) == .orderedSame }) {
            return [match]
        }

        let lowered = selector.lowercased()
        let nameMatches = apps.filter { ($0.localizedName ?? "").lowercased().contains(lowered) }
        guard !nameMatches.isEmpty else {
            throw UICtlError.message("no running application matches \"\(selector)\"")
        }
        return nameMatches
    }

    /// Resolves `selector` to a single best app, for call sites (`activate`,
    /// `elements`, `screenshot`, `ocr`, `waitFor`) that need exactly one.
    static func resolve(_ selector: String) throws -> NSRunningApplication {
        let matches = try resolveAll(selector)
        if matches.count == 1 {
            return matches[0]
        }

        // Multiple name matches (e.g. a relaunching app briefly listed twice):
        // prefer whichever candidate actually has on-screen windows, since a
        // stale/dying instance with none is never the one the caller wants.
        let withWindows = matches.filter { app in
            (try? AppsAndWindows.listWindows(pidFilter: [app.processIdentifier]))?.isEmpty == false
        }
        let candidates = withWindows.isEmpty ? matches : withWindows

        if let exact = candidates.first(where: { ($0.localizedName ?? "").caseInsensitiveCompare(selector) == .orderedSame }) {
            return exact
        }
        if let active = candidates.first(where: { $0.isActive }) {
            return active
        }
        return candidates[0]
    }
}
