import Foundation
import CryptoKit

/// A BitTorrent info hash — SHA-1 (v1) or SHA-256 (v2).
public struct InfoHash: Hashable, Sendable, CustomStringConvertible {
    public enum Version: Sendable {
        case v1  // SHA-1, 20 bytes
        case v2  // SHA-256, 32 bytes
    }

    public let bytes: Data
    public let version: Version

    public var description: String {
        bytes.map { ($0 < 16 ? "0" : "") + String($0, radix: 16) }.joined()
    }

    public var hex: String {
        description
    }

    /// Create an info hash from raw bytes.
    public init(bytes: Data) {
        self.bytes = bytes
        self.version = bytes.count == 32 ? .v2 : .v1
    }

    /// Compute SHA-1 info hash from the raw bencoded info dictionary.
    public static func v1(from infoData: Data) -> InfoHash {
        let digest = Insecure.SHA1.hash(data: infoData)
        return InfoHash(bytes: Data(digest))
    }

    /// Compute SHA-256 info hash from the raw bencoded info dictionary.
    public static func v2(from infoData: Data) -> InfoHash {
        let digest = SHA256.hash(data: infoData)
        return InfoHash(bytes: Data(digest))
    }

    /// Create from hex string.
    public init?(hex: String) {
        guard hex.count == 40 || hex.count == 64 else { return nil }
        var data = Data()
        var chars = hex.makeIterator()
        while let c1 = chars.next(), let c2 = chars.next() {
            guard let byte = UInt8(String([c1, c2]), radix: 16) else { return nil }
            data.append(byte)
        }
        self.init(bytes: data)
    }

    /// URL-encoded form for tracker announces (strictly RFC 3986 unreserved ASCII characters).
    public var urlEncoded: String {
        bytes.map { byte in
            switch byte {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x2D, 0x2E, 0x5F, 0x7E:
                return String(UnicodeScalar(byte))
            default:
                let hi = byte >> 4
                let lo = byte & 0x0F
                return "%" + String(hi, radix: 16).uppercased() + String(lo, radix: 16).uppercased()
            }
        }.joined()
    }
}


// MARK: - Identifiable & Codable
extension InfoHash: Identifiable {
    public var id: String { description }
}

extension InfoHash: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let hex = try container.decode(String.self)
        guard let hash = InfoHash(hex: hex) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid info hash hex string: \(hex)")
        }
        self = hash
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}
