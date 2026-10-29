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
