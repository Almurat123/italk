import Foundation

/// Streams one file into `<dest>.part`, appending as bytes arrive. Because the partial file holds real bytes (not opaque
/// resume data), a later attempt — from the same or a different source — continues with an HTTP Range request.
final class RangeDownloader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum Failure: Error, Equatable { case http(Int), rangeMismatch, tooLarge, network(String) }

    private let lock = NSLock()
    private var handle: FileHandle?
    private var continuation: CheckedContinuation<Void, Error>?
    private var written: Int64 = 0
    private var expected: Int64 = 0
    private var offset: Int64 = 0
    private var progress: (@Sendable (Int64) -> Void)?
    private var failure: Error?

    /// Returns when the server finished sending. Size/hash checks are the caller's job.
    func fetch(_ url: URL, part: URL, expectedTotal: Int64, session: URLSession, timeout: TimeInterval, progress: @escaping @Sendable (Int64) -> Void) async throws {
        if !FileManager.default.fileExists(atPath: part.path) { FileManager.default.createFile(atPath: part.path, contents: nil) }
        let existing = ModelStore.fileSize(part)
        if existing >= expectedTotal { return }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        if existing > 0 { req.setValue("bytes=\(existing)-", forHTTPHeaderField: "Range") }
        lock.withLock { offset = existing; written = existing; expected = expectedTotal; self.progress = progress; failure = nil }
        handle = try FileHandle(forWritingTo: part)
        try handle?.seekToEnd()
        let task = session.dataTask(with: req)
        task.delegate = self
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                lock.withLock { continuation = c }
                task.resume()
            }
        } onCancel: { task.cancel() }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse) async -> URLSession.ResponseDisposition {
        guard let http = response as? HTTPURLResponse else { return .allow }
        let start = lock.withLock { offset }
        switch http.statusCode {
        case 206:
            // Content-Range: bytes <start>-<end>/<total>
            let cr = http.value(forHTTPHeaderField: "Content-Range") ?? ""
            let s = cr.split(separator: " ").last?.split(separator: "-").first.flatMap { Int64($0) }
            if s != start { lock.withLock { failure = Failure.rangeMismatch }; return .cancel }
        case 200:
            // Server ignored Range: start over from byte 0.
            try? handle?.truncate(atOffset: 0)
            lock.withLock { offset = 0; written = 0 }
        case 416 where start > 0:
            lock.withLock { failure = Failure.http(416) }; return .cancel
        default:
            lock.withLock { failure = Failure.http(http.statusCode) }; return .cancel
        }
        return .allow
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let (over, now, cb) = lock.withLock { () -> (Bool, Int64, (@Sendable (Int64) -> Void)?) in
            written += Int64(data.count)
            return (written > expected, written, progress)
        }
        if over { lock.withLock { failure = Failure.tooLarge }; dataTask.cancel(); return }
        do { try handle?.write(contentsOf: data) } catch { lock.withLock { failure = error }; dataTask.cancel(); return }
        cb?(now)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? handle?.synchronize(); try? handle?.close(); handle = nil
        let (c, f) = lock.withLock { () -> (CheckedContinuation<Void, Error>?, Error?) in
            defer { continuation = nil }
            return (continuation, failure)
        }
        if let f { c?.resume(throwing: f) }
        else if let error { c?.resume(throwing: (error as? URLError)?.code == .cancelled ? CancellationError() : Failure.network((error as? URLError).map { "URLError \($0.code.rawValue)" } ?? "\(error)")) }
        else { c?.resume() }
    }
}
