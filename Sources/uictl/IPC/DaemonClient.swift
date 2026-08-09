import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Thin client: connects to the daemon's Unix socket, sends one framed JSON
/// request, reads one framed JSON response. If the daemon isn't running yet,
/// spawns it detached and waits briefly for the socket to come up.
enum DaemonClient {
    static func send(command: String, params: JSONDict) -> JSONDict {
        do {
            try ensureRunning()
            let fd = try connectSocket()
            defer { close(fd) }

            let request: JSONDict = ["command": command, "params": params]
            let requestData = try JSONSerialization.data(withJSONObject: request)
            try SocketIO.writeFrame(fd: fd, data: requestData)

            let responseData = try SocketIO.readFrame(fd: fd)
            guard let response = try JSONSerialization.jsonObject(with: responseData) as? JSONDict else {
                return errorResponse("daemon returned malformed response")
            }
            return response
        } catch {
            return errorResponse("\(error)")
        }
    }

    private static func connectSocket() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw UICtlError.message("socket() failed") }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(UICtlPaths.socketPath.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { rawPtr in
            let buf = rawPtr.bindMemory(to: Int8.self)
            for (i, byte) in pathBytes.enumerated() {
                buf[i] = Int8(bitPattern: byte)
            }
            buf[pathBytes.count] = 0
        }

        let result = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            close(fd)
            throw UICtlError.message("could not connect to daemon socket")
        }
        return fd
    }

    static func isRunning() -> Bool {
        guard let fd = try? connectSocket() else { return false }
        close(fd)
        return true
    }

    /// Spawns `uictl daemon start --foreground` as a detached background
    /// process (stdio redirected to a log file so it survives the parent
    /// shell command returning) and waits for the socket to appear.
    static func ensureRunning() throws {
        if isRunning() { return }

        try UICtlPaths.ensureHomeDir()
        FileManager.default.createFile(atPath: UICtlPaths.logFilePath, contents: nil)
        let logHandle = FileHandle(forWritingAtPath: UICtlPaths.logFilePath)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = ["daemon", "start", "--foreground"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = logHandle
        process.standardError = logHandle
        try process.run()

        for _ in 0..<50 {
            if isRunning() { return }
            usleep(100_000) // 100ms
        }
        throw UICtlError.message("daemon did not start within 5s; check \(UICtlPaths.logFilePath)")
    }
}
