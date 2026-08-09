import AppKit

/// Resolves the `--app` selector accepted by most subcommands: a numeric pid,
/// a reverse-DNS bundle identifier, or a case-insensitive substring of the
/// app's display name.
enum AppSelector {
    static func resolve(_ selector: String) throws -> NSRunningApplication {
        let apps = NSWorkspace.shared.runningApplications

        if let pid = Int32(selector), let match = apps.first(where: { $0.processIdentifier == pid }) {
            return match
        }

        if selector.contains("."), !selector.contains(" "),
           let match = apps.first(where: { $0.bundleIdentifier?.caseInsensitiveCompare(selector) == .orderedSame }) {
            return match
        }

        let lowered = selector.lowercased()
        let nameMatches = apps.filter { ($0.localizedName ?? "").lowercased().contains(lowered) }
        if nameMatches.count == 1 {
            return nameMatches[0]
        }
        if nameMatches.count > 1 {
            // Prefer an exact (case-insensitive) name match if present, else
            // the frontmost candidate, else just the first.
            if let exact = nameMatches.first(where: { ($0.localizedName ?? "").caseInsensitiveCompare(selector) == .orderedSame }) {
                return exact
            }
            if let active = nameMatches.first(where: { $0.isActive }) {
                return active
            }
            return nameMatches[0]
        }

        throw UICtlError.message("no running application matches \"\(selector)\"")
    }
}
