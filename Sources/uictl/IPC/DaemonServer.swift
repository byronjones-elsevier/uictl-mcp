import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Accepts one Unix-domain-socket connection at a time, reads a single framed
/// JSON request, dispatches it, writes a single framed JSON response, and closes
/// the connection. Kept deliberately simple (no concurrency) since every command
/// it dispatches to (Accessibility, CGEvent, ScreenCaptureKit) is happiest called
/// serially from one process anyway.
final class DaemonServer {
    private var listenFD: Int32 = -1

    func run(foreground: Bool) throws {
        try UICtlPaths.ensureHomeDir()
        try setupSocket()
        try String(getpid()).write(toFile: UICtlPaths.pidFilePath, atomically: true, encoding: .utf8)

        signal(SIGTERM) { _ in exit(0) }
        signal(SIGINT) { _ in exit(0) }
        signal(SIGPIPE, SIG_IGN)

        log("uictl daemon listening on \(UICtlPaths.socketPath) (pid \(getpid()))")

        while true {
            let clientFD = accept(listenFD, nil, nil)
            if clientFD < 0 {
                if errno == EINTR { continue }
                log("accept failed: \(String(cString: strerror(errno)))")
                continue
            }
            handle(clientFD: clientFD)
        }
    }

    private func setupSocket() throws {
        unlink(UICtlPaths.socketPath)

        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else {
            throw UICtlError.message("socket() failed: \(String(cString: strerror(errno)))")
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(UICtlPaths.socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            throw UICtlError.message("socket path too long: \(UICtlPaths.socketPath)")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { rawPtr in
            let buf = rawPtr.bindMemory(to: Int8.self)
            for (i, byte) in pathBytes.enumerated() {
                buf[i] = Int8(bitPattern: byte)
            }
            buf[pathBytes.count] = 0
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(listenFD, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            throw UICtlError.message("bind() failed: \(String(cString: strerror(errno)))")
        }
        guard listen(listenFD, 8) == 0 else {
            throw UICtlError.message("listen() failed: \(String(cString: strerror(errno)))")
        }
    }

    private func handle(clientFD: Int32) {
        defer { close(clientFD) }
        do {
            let requestData = try SocketIO.readFrame(fd: clientFD)
            guard let obj = try JSONSerialization.jsonObject(with: requestData) as? JSONDict,
                  let command = obj["command"] as? String else {
                try respond(clientFD, errorResponse("malformed request"))
                return
            }
            let params = (obj["params"] as? JSONDict) ?? [:]

            if command == "shutdown" {
                try respond(clientFD, successResponse("shutting down"))
                close(clientFD)
                unlink(UICtlPaths.socketPath)
                exit(0)
            }

            let response = CommandDispatcher.dispatch(command: command, params: params)
            try respond(clientFD, response)
        } catch {
            try? respond(clientFD, errorResponse("\(error)"))
        }
    }

    private func respond(_ fd: Int32, _ response: JSONDict) throws {
        let data = try JSONSerialization.data(withJSONObject: response)
        try SocketIO.writeFrame(fd: fd, data: data)
    }

    private func log(_ message: String) {
        FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    }
}
