import Foundation
import CadenciaCore

struct GPXImportStatus: Sendable {
    enum Stage: Sendable { case preparing, reading, parsing, analyzing, ready }
    var stage: Stage
    /// Unknown while a file provider prepares/downloads the document. After that, this is weighted
    /// work completed (bytes read, XML bytes consumed, points analyzed), not an elapsed-time estimate.
    var fractionCompleted: Double?
    var percentage: Int? { fractionCompleted.map { min(stage == .ready ? 100 : 99, max(0, Int(($0 * 100).rounded(.down)))) } }
    static let preparing = Self(stage: .preparing, fractionCompleted: nil)
}

/// File-provider access, disk reads, parsing and route calculations all happen off the main actor.
struct GPXImportService {
    enum Update: Sendable {
        case progress(GPXImportStatus)
        case finished([GPXRoute], source: Data)
    }

    func updates(for url: URL) -> AsyncThrowingStream<Update, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let access = GPXCoordinatedAccess()
            let progress = GPXImportProgressEmitter(continuation: continuation)
            let worker = Task.detached(priority: .userInitiated) {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    try Task.checkCancellation()
                    progress.report(.preparing)
                    var coordinationError: NSError?
                    var result: Result<[GPXRoute], Error>?
                    var source = Data()
                    // Coordinated reads materialize iCloud/Files-provider documents before opening them.
                    access.coordinator.coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { fileURL in
                        result = Result {
                            try Task.checkCancellation()
                            let file = try FileHandle(forReadingFrom: fileURL)
                            defer { try? file.close() }
                            let size = try file.seekToEnd()
                            guard size <= GPXImporter.maximumBytes else { throw GPXImporter.ImportError.tooLarge }
                            try file.seek(toOffset: 0)
                            var data = Data()
                            data.reserveCapacity(Int(size))
                            progress.report(GPXImportStatus(stage: .reading, fractionCompleted: 0))
                            while true {
                                try Task.checkCancellation()
                                guard let chunk = try file.read(upToCount: 64 * 1_024), !chunk.isEmpty else { break }
                                guard data.count + chunk.count <= GPXImporter.maximumBytes else { throw GPXImporter.ImportError.tooLarge }
                                data.append(chunk)
                                progress.report(GPXImportStatus(stage: .reading, fractionCompleted: 0.2 * min(1, Double(data.count) / Double(max(1, size)))))
                            }
                            try Task.checkCancellation()
                            progress.report(GPXImportStatus(stage: .parsing, fractionCompleted: 0.2))
                            source = data
                            return try GPXImporter().parse(data) { update in
                                switch update.stage {
                                case .parsing:
                                    progress.report(GPXImportStatus(stage: .parsing, fractionCompleted: 0.2 + 0.45 * update.fractionCompleted))
                                case .analyzing:
                                    progress.report(GPXImportStatus(stage: .analyzing, fractionCompleted: 0.65 + 0.35 * update.fractionCompleted))
                                }
                            }
                        }
                    }
                    try Task.checkCancellation()
                    if let coordinationError { throw coordinationError }
                    guard let result else { throw CocoaError(.fileReadUnknown) }
                    let routes = try result.get()
                    progress.report(GPXImportStatus(stage: .ready, fractionCompleted: 1))
                    continuation.yield(.finished(routes, source: source))
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { @Sendable _ in
                worker.cancel()
                access.coordinator.cancel()
            }
        }
    }
}

/// NSFileCoordinator.cancel() is designed to interrupt a coordinated operation from another thread.
private final class GPXCoordinatedAccess: @unchecked Sendable {
    let coordinator = NSFileCoordinator(filePresenter: nil)
}

/// Emit only stage/whole-percentage changes, keeping the UI queue bounded even for dense GPX files.
private final class GPXImportProgressEmitter: @unchecked Sendable {
    let continuation: AsyncThrowingStream<GPXImportService.Update, Error>.Continuation
    private let lock = NSLock()
    private var lastStage: GPXImportStatus.Stage?
    private var lastPercentage: Int?
    init(continuation: AsyncThrowingStream<GPXImportService.Update, Error>.Continuation) { self.continuation = continuation }
    func report(_ status: GPXImportStatus) {
        lock.lock(); defer { lock.unlock() }
        guard status.stage != lastStage || status.percentage != lastPercentage else { return }
        lastStage = status.stage; lastPercentage = status.percentage
        continuation.yield(.progress(status))
    }
}
