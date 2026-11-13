import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Downloads a file to a temporary location and reports progress (0…1) as it goes.
final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let shared = Downloader()

    private struct Job {
        let progress: @Sendable (Double) -> Void
        let continuation: CheckedContinuation<URL, Error>
    }

    private let lock = NSLock()
    private var jobs: [Int: Job] = [:]
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    func download(_ url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let task = session.downloadTask(with: url)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<URL, Error>) in
                lock.lock()
                jobs[task.taskIdentifier] = Job(progress: progress, continuation: c)
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    private func take(_ id: Int) -> Job? {
        lock.lock()
        defer { lock.unlock() }
        return jobs.removeValue(forKey: id)
    }

    private func job(_ id: Int) -> Job? {
        lock.lock()
        defer { lock.unlock() }
        return jobs[id]
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        job(downloadTask.taskIdentifier)?.progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let job = take(downloadTask.taskIdentifier) else { return }
        // The file is removed when this returns, so move it first.
        let kept = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            if let status = (downloadTask.response as? HTTPURLResponse)?.statusCode, status != 200 {
                throw URLError(.badServerResponse)
            }
            try FileManager.default.moveItem(at: location, to: kept)
            job.continuation.resume(returning: kept)
        } catch {
            job.continuation.resume(throwing: error)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let job = take(task.taskIdentifier) else { return }
        job.continuation.resume(throwing: error)
    }
}
