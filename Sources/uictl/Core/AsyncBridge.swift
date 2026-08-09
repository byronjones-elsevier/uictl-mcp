import Foundation

/// The daemon's request handling is deliberately synchronous (one request at a
/// time, blocking IPC), but ScreenCaptureKit is async-only. This blocks the
/// calling thread on a semaphore while the async work runs on a Task, which is
/// the standard bridge for a script-like synchronous CLI calling an async API.
func runSync<T>(_ operation: @escaping () async throws -> T) throws -> T {
    let semaphore = DispatchSemaphore(value: 0)
    var result: Result<T, Error>?
    Task {
        do {
            result = .success(try await operation())
        } catch {
            result = .failure(error)
        }
        semaphore.signal()
    }
    semaphore.wait()
    return try result!.get()
}
