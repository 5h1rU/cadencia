import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct HTTPRequest: Sendable, Equatable {
    public enum Method: String, Sendable { case get = "GET", post = "POST", put = "PUT", delete = "DELETE" }
    public var method: Method
    public var url: URL
    public var headers: [String: String]
    public var body: Data?

    public init(method: Method, url: URL, headers: [String: String] = [:], body: Data? = nil) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }
}

public struct HTTPResponse: Sendable, Equatable {
    public var status: Int
    public var body: Data
    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }
    public var isSuccess: Bool { (200..<300).contains(status) }
}

/// The only thing the clients need from the network. `URLSession` conforms; tests use a recorder.
public protocol HTTPTransport: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

public enum HTTPError: Error, Equatable, Sendable {
    case status(Int, String)
    case unauthorized
    case transport(String)
    case invalidResponse

    public var isAuthFailure: Bool {
        if case .unauthorized = self { return true }
        if case .status(let code, _) = self, code == 401 || code == 403 { return true }
        return false
    }
}

extension URLSession: HTTPTransport {
    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var r = URLRequest(url: request.url)
        r.httpMethod = request.method.rawValue
        r.httpBody = request.body
        for (k, v) in request.headers { r.setValue(v, forHTTPHeaderField: k) }
        let (data, response) = try await data(for: r)
        guard let http = response as? HTTPURLResponse else { throw HTTPError.invalidResponse }
        return HTTPResponse(status: http.statusCode, body: data)
    }
}

/// Builds a multipart/form-data body for file uploads (Intervals.icu activity upload).
public struct MultipartBody: Sendable {
    public let boundary: String
    private var data = Data()

    public init(boundary: String = "cadencia-\(UUID().uuidString)") {
        self.boundary = boundary
    }

    public mutating func addField(name: String, value: String) {
        data.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
    }

    public mutating func addFile(name: String, filename: String, contentType: String, contents: Data) {
        data.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\nContent-Type: \(contentType)\r\n\r\n".data(using: .utf8)!)
        data.append(contents)
        data.append("\r\n".data(using: .utf8)!)
    }

    public var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    public func finish() -> Data {
        var d = data
        d.append("--\(boundary)--\r\n".data(using: .utf8)!)
        return d
    }
}
