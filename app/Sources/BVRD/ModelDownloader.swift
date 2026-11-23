import CryptoKit
import Foundation

/// Files listed in model_manifest.json.
struct ModelManifest: Decodable {
    struct Folder: Decodable {
        let name: String
        let repo: String
        let revision: String
        let files: [File]
    }

    struct File: Decodable {
        let path: String
        let size: Int64
        let sha256: String
    }

    let folders: [Folder]

    var totalBytes: Int64 { folders.flatMap(\.files).reduce(0) { $0 + $1.size } }

    static func load() -> ModelManifest {
        guard let data = try? Data(contentsOf: AppInfo.manifestURL),
              let manifest = try? JSONDecoder().decode(ModelManifest.self, from: data) else {
            return ModelManifest(folders: [])
        }
        return manifest
    }
}

/// Download the voice model. Resumes, then checks each file.
@MainActor
final class ModelDownloader: ObservableObject {
    enum State: Equatable {
        case notInstalled, downloading, verifying, failed(String), installed
    }

    @Published private(set) var state: State
    @Published private(set) var receivedBytes: Int64 = 0
    @Published private(set) var bytesPerSecond: Double = 0

    let manifest = ModelManifest.load()
    var totalBytes: Int64 { manifest.totalBytes }
    var isInstalled: Bool { state == .installed }
    var onInstalled: (() -> Void)?

    private var task: Task<Void, Never>?
    private var speedSample: (time: Date, bytes: Int64)?

    init() {
        state = .notInstalled
        if !manifest.folders.isEmpty && missingFiles().isEmpty {
            state = .installed
        }
    }

    private func destination(_ folder: ModelManifest.Folder, _ file: ModelManifest.File) -> URL {
        AppInfo.modelURL.appendingPathComponent(folder.name).appendingPathComponent(file.path)
    }

    private func partial(_ folder: ModelManifest.Folder, _ file: ModelManifest.File) -> URL {
        AppInfo.modelURL.appendingPathComponent(".partial").appendingPathComponent(folder.name).appendingPathComponent(file.path + ".part")
    }

    private static func size(of url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }

    /// A file only counts once its checksum matches.
    private func missingFiles() -> [(ModelManifest.Folder, ModelManifest.File)] {
        manifest.folders.flatMap { folder in
            folder.files.filter { Self.size(of: destination(folder, $0)) != $0.size }.map { (folder, $0) }
        }
    }

    func start() {
        guard task == nil, !isInstalled else { return }
        task = Task { await run() }
    }

    func cancel() {
        task?.cancel()
    }

    private func run() async {
        defer { task = nil }
        state = .downloading
        bytesPerSecond = 0
        speedSample = nil
        do {
            let missing = missingFiles()
            let alreadyDone = totalBytes - missing.reduce(0) { $0 + $1.1.size }
            let partialBytes = missing.reduce(Int64(0)) { $0 + (Self.size(of: partial($1.0, $1.1)) ?? 0) }
            try checkFreeSpace(needed: totalBytes - alreadyDone - partialBytes)

            var completed = alreadyDone
            receivedBytes = completed
            for (folder, file) in missing {
                let part = partial(folder, file)
                let dest = destination(folder, file)
                try FileManager.default.createDirectory(at: part.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)

                let url = URL(string: "https://huggingface.co/\(folder.repo)/resolve/\(folder.revision)/\(file.path)")!
                let base = completed
                try await FileDownload(destination: part) { [weak self] written in
                    Task { @MainActor in self?.update(received: base + written) }
                }.run(url: url)

                state = .verifying
                let digest = try await Task.detached { try Self.sha256(of: part) }.value
                guard digest == file.sha256 else {
                    try? FileManager.default.removeItem(at: part)
                    throw DownloadError.checksum(file.path)
                }
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: part, to: dest)
                completed += file.size
                receivedBytes = completed
                state = .downloading
            }
            try? FileManager.default.removeItem(at: AppInfo.modelURL.appendingPathComponent(".partial"))
            state = .installed
            onInstalled?()
        } catch is CancellationError {
            state = .notInstalled
        } catch let error as URLError where error.code == .cancelled {
            state = .notInstalled
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func update(received: Int64) {
        guard state == .downloading else { return }
        receivedBytes = received
        let now = Date()
        if let sample = speedSample {
            let elapsed = now.timeIntervalSince(sample.time)
            if elapsed >= 1 {
                let current = Double(received - sample.bytes) / elapsed
                bytesPerSecond = bytesPerSecond == 0 ? current : bytesPerSecond * 0.7 + current * 0.3
                speedSample = (now, received)
            }
        } else {
            speedSample = (now, received)
        }
    }

    private func checkFreeSpace(needed: Int64) throws {
        try FileManager.default.createDirectory(at: AppInfo.modelURL, withIntermediateDirectories: true)
        let values = try AppInfo.modelURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let free = values.volumeAvailableCapacityForImportantUsage, free < needed + 500_000_000 {
            throw DownloadError.diskFull(needed)
        }
    }

    nonisolated private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 16 * 1024 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

enum DownloadError: LocalizedError {
    case http(Int), checksum(String), diskFull(Int64)

    var errorDescription: String? {
        switch self {
        case .http(let code):
            return "The download server returned an error (HTTP \(code)). Check your internet connection and try again."
        case .checksum(let file):
            return "\(file) didn't download correctly. Try again."
        case .diskFull(let bytes):
            let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            return "Not enough free disk space. The voice model needs about \(size)."
        }
    }
}

/// Download one file, picking up where it left off.
private final class FileDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let destination: URL
    private let progress: (Int64) -> Void
    private var handle: FileHandle?
    private var written: Int64 = 0
    private var failure: Error?
    private var continuation: CheckedContinuation<Void, Error>?

    init(destination: URL, progress: @escaping (Int64) -> Void) {
        self.destination = destination
        self.progress = progress
    }

    func run(url: URL) async throws {
        let existing = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value ?? 0
        var request = URLRequest(url: url)
        if existing > 0 {
            request.setValue("bytes=\(existing)-", forHTTPHeaderField: "Range")
        }
        written = existing
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: queue)
        defer { session.finishTasksAndInvalidate() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                queue.addOperation {
                    self.continuation = continuation
                    session.dataTask(with: request).resume()
                }
            }
        } onCancel: {
            session.invalidateAndCancel()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        do {
            switch code {
            case 206:
                handle = try FileHandle(forWritingTo: destination)
                try handle?.seekToEnd()
            case 200:
                FileManager.default.createFile(atPath: destination.path, contents: nil)
                handle = try FileHandle(forWritingTo: destination)
                written = 0
            case 416:
                // Already the full file, or bigger. The checksum decides.
                completionHandler(.cancel)
                finish(nil)
                return
            default:
                throw DownloadError.http(code)
            }
            completionHandler(.allow)
        } catch {
            failure = error
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            try handle?.write(contentsOf: data)
            written += Int64(data.count)
            progress(written)
        } catch {
            failure = error
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finish(failure ?? error)
    }

    private func finish(_ error: Error?) {
        try? handle?.close()
        handle = nil
        guard let continuation else { return }
        self.continuation = nil
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }
}
