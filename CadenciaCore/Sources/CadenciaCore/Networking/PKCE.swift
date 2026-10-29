import Foundation

/// RFC 7636 verifier + S256 challenge, shared by every OAuth flow in the app.
public struct PKCE: Sendable, Equatable {
    public let verifier: String
    public let challenge: String

    /// Generates a 64-char verifier from the unreserved alphabet and its S256 challenge.
    public static func make(randomBytes: [UInt8]? = nil) -> PKCE {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let bytes = randomBytes ?? (0..<64).map { _ in UInt8.random(in: 0...255) }
        let verifier = String(bytes.prefix(64).map { alphabet[Int($0) % alphabet.count] })
        let digest = SHA256.hash(Array(verifier.utf8))
        return PKCE(verifier: verifier, challenge: Base64URL.encode(Data(digest)))
    }
}

enum Base64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ s: String) -> Data? {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        return Data(base64Encoded: b)
    }
}

/// `application/x-www-form-urlencoded` body with stable key order (tests compare bodies).
enum FormBody {
    static func encode(_ fields: [(String, String)]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let s = fields.map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.1)" }.joined(separator: "&")
        return Data(s.utf8)
    }
}
