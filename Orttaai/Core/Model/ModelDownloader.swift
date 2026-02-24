// ModelDownloader.swift
// Orttaai

import Foundation
import CommonCrypto
import UserNotifications
import os

struct DownloadProgress {
    let percentage: Double
    let bytesDownloaded: Int64
    let totalBytes: Int64
    let speed: Double // bytes per second
    let eta: TimeInterval // seconds remaining
}

@Observable
final class ModelDownloader: NSObject {
    private(set) var progress: DownloadProgress?
    private(set) var isDownloading = false
    private(set) var error: Error?

    private var session: URLSession!
    private var currentTask: URLSessionDownloadTask?
    private var resumeData: Data?
    private var startTime: Date?
    private var retryCount = 0
    private let maxRetries = 3

    private var continuation: CheckedContinuation<URL, Error>?

    override init() {
        super.init()
        let config = URLSessionConfiguration.background(withIdentifier: "com.orttaai.modeldownload")
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }

    func download(from url: URL, to destinationDir: URL) async throws -> URL {
        isDownloading = true
        error = nil
        startTime = Date()
        retryCount = 0

        // Ensure destination directory exists
        try FileManager.default.createDirectory(at: destinationDir, withIntermediateDirectories: true)

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation

            if let resumeData = resumeData {
                currentTask = session.downloadTask(withResumeData: resumeData)
                self.resumeData = nil
            } else {
                currentTask = session.downloadTask(with: url)
            }
            currentTask?.resume()
        }
    }

    func cancel() {
        currentTask?.cancel(byProducingResumeData: { [weak self] data in
            self?.resumeData = data
        })
        isDownloading = false
    }

    static func verifySHA256(of fileURL: URL, expected: String) -> Bool {
        guard let data = try? Data(contentsOf: fileURL) else { return false }

        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(data.count), &hash)
        }

        let computed = hash.map { String(format: "%02x", $0) }.joined()
        return computed.lowercased() == expected.lowercased()
    }

    static func postDownloadNotification(modelName: String) {
        let content = UNMutableNotificationContent()
        content.title = "Orttaai"
        content.body = "Model downloaded. Ready to dictate."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "model-download-complete",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                Logger.model.error("Failed to post notification: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Private

    private func retryAfterDelay() {
        guard retryCount < maxRetries else {
            let err = OrttaaiError.downloadFailed
            error = err
            isDownloading = false
            continuation?.resume(throwing: err)
            continuation = nil
            return
        }

        retryCount += 1
        let delay = pow(2.0, Double(retryCount)) // 2s, 4s, 8s
        Logger.model.info("Retrying download in \(delay)s (attempt \(self.retryCount)/\(self.maxRetries))")

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self else { return }
            if let resumeData = self.resumeData {
                self.currentTask = self.session.downloadTask(withResumeData: resumeData)
                self.resumeData = nil
            }
            self.currentTask?.resume()
        }
    }
}

extension ModelDownloader: URLSessionDownloadDelegate {
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // Move to permanent location
        let fileName = downloadTask.originalRequest?.url?.lastPathComponent ?? "model"
        let destDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Orttaai/Models")
        let destURL = destDir.appendingPathComponent(fileName)

        do {
            try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destURL.path) {
                try FileManager.default.removeItem(at: destURL)
            }
            try FileManager.default.moveItem(at: location, to: destURL)

            isDownloading = false
            Logger.model.info("Download complete: \(destURL.path)")

            continuation?.resume(returning: destURL)
            continuation = nil
        } catch {
            self.error = error
            isDownloading = false
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let percentage = totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            : 0

        let elapsed = Date().timeIntervalSince(startTime ?? Date())
        let speed = elapsed > 0 ? Double(totalBytesWritten) / elapsed : 0
        let remaining = speed > 0 ? Double(totalBytesExpectedToWrite - totalBytesWritten) / speed : 0

        progress = DownloadProgress(
            percentage: percentage,
            bytesDownloaded: totalBytesWritten,
            totalBytes: totalBytesExpectedToWrite,
            speed: speed,
            eta: remaining
        )
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error = error else { return }

        let nsError = error as NSError
        if nsError.code == NSURLErrorCancelled {
            // User cancelled — don't retry
            isDownloading = false
            self.continuation?.resume(throwing: error)
            self.continuation = nil
            return
        }

        // Save resume data if available
        if let resumeData = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            self.resumeData = resumeData
        }

        Logger.model.error("Download error: \(error.localizedDescription)")
        retryAfterDelay()
    }
}
