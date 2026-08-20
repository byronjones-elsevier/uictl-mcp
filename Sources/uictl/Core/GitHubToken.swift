import Foundation

/// Resolves a GitHub token for the (optional) duplicate-issue check, without
/// requiring the user to do anything if they already have working GitHub
/// credentials on this machine.
enum GitHubToken {
    /// Precedence: an explicit `--token`/`token` param, then the standard
    /// `GITHUB_TOKEN` environment variable, then whatever the `gh` CLI (if
    /// installed and already authenticated — as it commonly is on a dev
    /// machine) has stored. Returns `nil` if none of those pan out, so
    /// callers can degrade gracefully (skip the check) instead of failing.
    static func resolve(explicit: String?) -> String? {
        if let explicit, !explicit.isEmpty { return explicit }
        if let envToken = ProcessInfo.processInfo.environment["GITHUB_TOKEN"], !envToken.isEmpty {
            return envToken
        }
        return fromGHCLI()
    }

    private static func fromGHCLI() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["gh", "auth", "token"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else {
            return nil
        }
        return token
    }
}
