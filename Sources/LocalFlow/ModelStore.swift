import CryptoKit
import Foundation

/// The two model files LocalFlow downloads on first run, pinned to an exact upstream commit
/// and checked against their published SHA-256 before use.
struct ModelFile: Equatable {
    let title: String
    let fileName: String
    let url: URL
    let size: Int64
    let sha256: String

    static let speech = ModelFile(
        title: "Speech model (Whisper small.en)",
        fileName: "ggml-small.en.bin",
        url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-small.en.bin")!,
        size: 487_614_201,
        sha256: "c6138d6d58ecc8322097e0f987c32f1be8bb0a18532a3f88f734d1bbf9c41e5d"
    )

    static let cleanup = ModelFile(
        title: "Cleanup model (Qwen 2.5 7B)",
        fileName: "Qwen2.5-7B-Instruct-Q4_K_M.gguf",
        url: URL(string: "https://huggingface.co/bartowski/Qwen2.5-7B-Instruct-GGUF/resolve/8911e8a47f92bac19d6f5c64a2e2095bd2f7d031/Qwen2.5-7B-Instruct-Q4_K_M.gguf")!,
        size: 4_683_074_240,
        sha256: "65b8fcd92af6b4fefa935c625d1ac27ea29dcb6ee14589c55a8f115ceaaa1423"
    )

    static let all = [speech, cleanup]
}

enum ModelStore {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("LocalFlow/models", isDirectory: true)
    }

    static func url(for model: ModelFile) -> URL {
        directory.appendingPathComponent(model.fileName)
    }

    /// A file counts as installed when its size matches; the checksum is verified once, at download.
    static func isInstalled(_ model: ModelFile) -> Bool {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url(for: model).path)
        return (attributes?[.size] as? NSNumber)?.int64Value == model.size
    }

    static var allInstalled: Bool { ModelFile.all.allSatisfy(isInstalled) }

    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

enum ModelDownloadError: LocalizedError {
    case notEnoughSpace(neededGB: Double)
    case badStatus(Int)
    case checksumMismatch(String)

    var errorDescription: String? {
        switch self {
        case .notEnoughSpace(let gb):
            return String(format: "Not enough free disk space: %.1f GB is needed.", gb)
        case .badStatus(let code):
            return "The download server answered HTTP \(code). Try again in a minute."
        case .checksumMismatch(let name):
            return "\(name) did not match its published checksum, so it was deleted. Try again."
        }
    }
}

/// Downloads one model file with progress, verifies it, and moves it into place.
final class ModelDownloader: NSObject, URLSessionDownloadDelegate {
    private var session: URLSession!
    private var continuation: CheckedContinuation<URL, Error>?
    private let onProgress: (Double) -> Void

    init(onProgress: @escaping (Double) -> Void) {
        self.onProgress = onProgress
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }

    static func checkSpace(for models: [ModelFile]) throws {
        let needed = models.filter { !ModelStore.isInstalled($0) }.reduce(Int64(0)) { $0 + $1.size }
        guard needed > 0 else { return }
        try FileManager.default.createDirectory(at: ModelStore.directory, withIntermediateDirectories: true)
        let values = try ModelStore.directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        let free = values.volumeAvailableCapacityForImportantUsage ?? .max
        let margin: Int64 = 1 << 30
        if free < needed + margin {
            throw ModelDownloadError.notEnoughSpace(neededGB: Double(needed + margin) / 1e9)
        }
    }

    func download(_ model: ModelFile) async throws {
        try FileManager.default.createDirectory(at: ModelStore.directory, withIntermediateDirectories: true)
        let temporary = try await withCheckedThrowingContinuation { (c: CheckedContinuation<URL, Error>) in
            continuation = c
            session.downloadTask(with: model.url).resume()
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let digest = try await Task.detached(priority: .userInitiated) { try ModelStore.sha256(of: temporary) }.value
        guard digest == model.sha256 else { throw ModelDownloadError.checksumMismatch(model.title) }
        let destination = ModelStore.url(for: model)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
    }

    func cancel() {
        session.invalidateAndCancel()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            continuation?.resume(throwing: ModelDownloadError.badStatus(http.statusCode))
            continuation = nil
            return
        }
        // The system deletes `location` when this returns, so move it somewhere we own first.
        let kept = ModelStore.directory.appendingPathComponent(UUID().uuidString + ".part")
        do {
            try FileManager.default.moveItem(at: location, to: kept)
            continuation?.resume(returning: kept)
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        continuation?.resume(throwing: error)
        continuation = nil
    }
}
