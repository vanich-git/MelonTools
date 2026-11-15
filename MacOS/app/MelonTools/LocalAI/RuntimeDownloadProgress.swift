import Foundation

final class RuntimeDownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let report: @Sendable (Int64, Int64) -> Void
    private var lastReport = Date.distantPast
    private let lock = NSLock()
    private var exceeded = false

    var exceededLimit: Bool {
        lock.lock(); defer { lock.unlock() }
        return exceeded
    }

    init(report: @escaping @Sendable (Int64, Int64) -> Void) { self.report = report }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > RuntimePackageInstaller.maximumArchiveBytes ||
            totalBytesExpectedToWrite > RuntimePackageInstaller.maximumArchiveBytes {
            lock.lock(); exceeded = true; lock.unlock()
            downloadTask.cancel()
            return
        }
        if Date().timeIntervalSince(lastReport) >= 0.15 {
            lastReport = Date()
            report(totalBytesWritten, max(0, totalBytesExpectedToWrite))
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {}

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.user == nil, url.password == nil else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}
