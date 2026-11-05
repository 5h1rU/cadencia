import Foundation

/// Small JSON-on-disk store under Application Support. One file per key; rides live in a subfolder.
struct JSONStore {
    let root: URL

    static func live() -> JSONStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let root = base.appendingPathComponent("Cadencia", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return JSONStore(root: root)
    }

    static func temporary() -> JSONStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Cadencia-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return JSONStore(root: root)
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    func url(_ path: String) -> URL { root.appendingPathComponent(path) }

    func load<T: Decodable>(_ type: T.Type, at path: String) -> T? {
        guard let data = try? Data(contentsOf: url(path)) else { return nil }
        return try? Self.decoder.decode(T.self, from: data)
    }

    /// `load(_:at:)` for callers that must not mistake an unreadable file for a missing one: nil when the
    /// file does not exist or does not decode, and a thrown error when it exists but cannot be read right
    /// now, as `.completeFileProtection` files cannot while the device is locked.
    func loadIfPresent<T: Decodable>(_ type: T.Type, at path: String) throws -> T? {
        let target = url(path)
        let data: Data
        do { data = try Data(contentsOf: target) } catch {
            // File metadata stays readable while the device is locked, so existence still tells the two apart.
            guard FileManager.default.fileExists(atPath: target.path) else { return nil }
            throw error
        }
        return try? Self.decoder.decode(T.self, from: data)
    }

    func save<T: Encodable>(_ value: T, at path: String) throws {
        let target = url(path)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try Self.encoder.encode(value)
        try data.write(to: target, options: [.atomic, .completeFileProtection])
    }

    func remove(at path: String) {
        try? FileManager.default.removeItem(at: url(path))
    }

    func removeAll() {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
}

/// Writes the app's JSON files off the main thread, on one serial queue. State snapshots coalesce: a newer
/// snapshot replaces one still waiting, so only the newest is encoded. Everything runs in FIFO order, so a
/// ride file never lands after a later write of the same file.
///
/// Nothing on the queue ever waits for the main thread, which is what makes the synchronous `flush()` and
/// `writeNow(_:)` safe to call from it.
final class PersistenceQueue: @unchecked Sendable {
    private let store: JSONStore
    private let statePath: String
    private let queue = DispatchQueue(label: "Cadencia.persistence", qos: .userInitiated)
    private let lock = NSLock()
    // Guarded by `lock`.
    private var pendingState: AppState?
    private var drainQueued = false
    private var errorHandler: (@Sendable (String) -> Void)?

    init(store: JSONStore, statePath: String) {
        self.store = store
        self.statePath = statePath
    }

    /// Receives the message of a failed state write. Called on whichever thread runs the write: the writer's
    /// queue, or the main thread inside `flush()` (`queue.sync` runs there). It must never block on the main thread.
    var onError: (@Sendable (String) -> Void)? {
        get { lock.withLock { errorHandler } }
        set { lock.withLock { errorHandler = newValue } }
    }

    /// Queues an O(1) copy-on-write snapshot of the state; it is encoded and written on the queue.
    func submit(_ state: AppState) {
        let schedule = lock.withLock { () -> Bool in
            pendingState = state
            defer { drainQueued = true }
            return !drainQueued
        }
        if schedule { queue.async { self.drainState() } }
    }

    /// Runs `work` after everything queued before it and hands back its result. Ride files use this.
    func write(_ work: @escaping @Sendable () throws -> Void) async throws {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            queue.async { done.resume(with: Result { try work() }) }
        }
    }

    /// `write(_:)` for a synchronous caller that needs the error: blocks until `work` and everything queued
    /// before it has run.
    func writeNow(_ work: () throws -> Void) throws {
        try queue.sync(execute: work)
    }

    /// Fire-and-forget work in queue order, for cleanups that must follow the writes queued before them.
    func enqueue(_ work: @escaping @Sendable () -> Void) {
        queue.async(execute: work)
    }

    /// Returns once everything queued so far, including a pending state snapshot, is on disk, without
    /// blocking the caller's thread.
    func settle() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.async {
                self.drainState()
                done.resume()
            }
        }
    }

    /// Blocks until everything queued so far, including a pending state snapshot, is on disk. For app
    /// backgrounding and account changes.
    func flush() {
        queue.sync { drainState() }
    }

    private func drainState() {
        let (snapshot, handler) = lock.withLock { () -> (AppState?, (@Sendable (String) -> Void)?) in
            defer { pendingState = nil; drainQueued = false }
            return (pendingState, errorHandler)
        }
        guard let snapshot else { return }
        do { try store.save(snapshot, at: statePath) } catch { handler?(error.localizedDescription) }
    }
}
