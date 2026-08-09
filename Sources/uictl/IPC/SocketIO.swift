import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Length-prefixed JSON framing over a blocking Unix domain socket: a 4-byte
/// big-endian length header followed by exactly that many bytes of JSON payload.
/// One request/response pair per connection, so there is no message interleaving
/// to worry about.
enum SocketIO {
    static func writeFrame(fd: Int32, data: Data) throws {
        try writeAll(fd: fd, data: encodeLength(data.count))
        try writeAll(fd: fd, data: data)
    }

    static func readFrame(fd: Int32) throws -> Data {
        let header = try readExact(fd: fd, count: 4)
        let length = decodeLength(header)
        guard length > 0, length < 64 * 1024 * 1024 else {
            throw UICtlError.message("invalid IPC frame length \(length)")
        }
        return try readExact(fd: fd, count: length)
    }

    private static func encodeLength(_ length: Int) -> Data {
        Data([
            UInt8((length >> 24) & 0xFF),
            UInt8((length >> 16) & 0xFF),
            UInt8((length >> 8) & 0xFF),
            UInt8(length & 0xFF),
        ])
    }

    private static func decodeLength(_ data: Data) -> Int {
        let b = [UInt8](data)
        return (Int(b[0]) << 24) | (Int(b[1]) << 16) | (Int(b[2]) << 8) | Int(b[3])
    }

    private static func writeAll(fd: Int32, data: Data) throws {
        var offset = 0
        let count = data.count
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            while offset < count {
                let n = write(fd, base.advanced(by: offset), count - offset)
                if n <= 0 {
                    if errno == EINTR { continue }
                    throw UICtlError.message("socket write failed: \(String(cString: strerror(errno)))")
                }
                offset += n
            }
        }
    }

    private static func readExact(fd: Int32, count: Int) throws -> Data {
        var buffer = Data(count: count)
        var offset = 0
        try buffer.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            while offset < count {
                let n = read(fd, base.advanced(by: offset), count - offset)
                if n == 0 { throw UICtlError.message("socket closed by peer") }
                if n < 0 {
                    if errno == EINTR { continue }
                    throw UICtlError.message("socket read failed: \(String(cString: strerror(errno)))")
                }
                offset += n
            }
        }
        return buffer
    }
}
