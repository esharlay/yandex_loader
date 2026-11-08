import Foundation

typealias ByteProgress = @Sendable (Int64, Int64) -> Void

/// A separate delegate per URLSession task keeps each file's byte count independent.
final class NetworkProgressDelegate: NSObject, URLSessionTaskDelegate, URLSessionDownloadDelegate, @unchecked Sendable {
    private let callback: ByteProgress
    private let fallbackTotal: Int64
    private let lock = NSLock()
    private var lastTime: TimeInterval = 0
    private var highWater: Int64 = 0
    init(expected: Int64, callback: @escaping ByteProgress) { fallbackTotal = expected; self.callback = callback }
    func report(_ bytes: Int64, total: Int64, force: Bool = false) {
        lock.lock()
        highWater = max(highWater, bytes)
        let declared = max(total, fallbackTotal)
        let expected = declared > 0 ? max(declared, highWater) : 0
        let now = ProcessInfo.processInfo.systemUptime
        let send = force || now - lastTime >= 0.08 || declared > 0 && highWater >= declared
        if send { lastTime = now }
        let count = highWater
        lock.unlock()
        if send { callback(count, expected) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) { report(totalBytesSent, total: totalBytesExpectedToSend) }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) { report(totalBytesWritten, total: totalBytesExpectedToWrite) }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) { }
}

/// Async URLSession.download(for:delegate:) does not forward download byte events
/// to its per-task delegate on macOS. Use an ordinary session download delegate instead.
final class NetworkDownloadOperation: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let configuration: URLSessionConfiguration
    private let reporter: NetworkProgressDelegate
    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var continuation: CheckedContinuation<(URL, URLResponse), Error>?
    private var cancelled = false
    private var result: (URL, URLResponse)?
    private var fileError: Error?

    init(configuration: URLSessionConfiguration, expected: Int64, progress: @escaping ByteProgress) {
        self.configuration = configuration; reporter = NetworkProgressDelegate(expected: expected, callback: progress)
    }
    static func download(_ request: URLRequest, configuration: URLSessionConfiguration, expected: Int64, progress: @escaping ByteProgress) async throws -> (URL, URLResponse) {
        let operation = NetworkDownloadOperation(configuration: configuration, expected: expected, progress: progress)
        return try await operation.run(request)
    }
    private func run(_ request: URLRequest) async throws -> (URL, URLResponse) {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if cancelled { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                self.continuation = continuation
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                let task = session.downloadTask(with: request)
                self.session = session; self.task = task
                lock.unlock(); task.resume()
            }
        }, onCancel: { self.cancel() })
    }
    private func cancel() { lock.lock(); cancelled = true; let task = task; lock.unlock(); task?.cancel() }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) { reporter.report(totalBytesWritten, total: totalBytesExpectedToWrite) }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let retained = FileManager.default.temporaryDirectory.appendingPathComponent("YandexLoaderDownload-" + UUID().uuidString)
        do {
            guard let response = downloadTask.response else { throw LoaderError.message("Не получен ответ при скачивании файла.") }
            try FileManager.default.moveItem(at: location, to: retained)
            result = (retained, response)
        } catch { fileError = error; try? FileManager.default.removeItem(at: retained) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = continuation; self.continuation = nil
        let wasCancelled = cancelled
        self.task = nil; self.session = nil
        lock.unlock()
        let failure: Error? = wasCancelled ? CancellationError() : error ?? fileError
        if let failure {
            if let result { try? FileManager.default.removeItem(at: result.0) }
            continuation?.resume(throwing: failure)
        } else if let result {
            let size = (try? FileManager.default.attributesOfItem(atPath: result.0.path)[.size] as? NSNumber)?.int64Value ?? 0
            reporter.report(size, total: size, force: true)
            continuation?.resume(returning: result)
        } else { continuation?.resume(throwing: LoaderError.message("Скачивание завершилось без файла.")) }
        session.finishTasksAndInvalidate()
    }
}
