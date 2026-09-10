import Foundation
import CryptoKit

/// A BitTorrent info hash — SHA-1 (v1), SHA-256 (v2), or hybrid (both).
public struct InfoHash: Hashable, Sendable, CustomStringConvertible {
    public enum Version: Sendable {
        case v1      // SHA-1, 20 bytes
        case v2      // SHA-256, 32 bytes
        case hybrid  // Both v1 and v2
    }

    public let bytes: Data
    public let version: Version

    /// For hybrid torrents, the v2 hash (32 bytes). Nil for pure v1 torrents.
    public let v2Bytes: Data?

    public var description: String {
        bytes.map { ($0 < 16 ? "0" : "") + String($0, radix: 16) }.joined()
    }

    public var hex: String {
        description
    }

    /// The v2 hex string (64 chars), or nil if this is a pure v1 hash.
    public var v2Hex: String? {
        v2Bytes?.map { ($0 < 16 ? "0" : "") + String($0, radix: 16) }.joined()
    }

    /// Create an info hash from raw bytes.
    public init(bytes: Data) {
        self.bytes = bytes
        self.version = bytes.count == 32 ? .v2 : .v1
        self.v2Bytes = bytes.count == 32 ? bytes : nil
    }

    /// Create a hybrid info hash with both v1 and v2 hashes.
    public init(v1Bytes: Data, v2Bytes: Data) {
        self.bytes = v1Bytes
        self.v2Bytes = v2Bytes
        self.version = .hybrid
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

    /// Compute both v1 and v2 hashes from the same info dictionary data.
    public static func hybrid(from infoData: Data) -> InfoHash {
        let sha1 = Data(Insecure.SHA1.hash(data: infoData))
        let sha256 = Data(SHA256.hash(data: infoData))
        return InfoHash(v1Bytes: sha1, v2Bytes: sha256)
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

    /// Create from multihash-encoded v2 hash (e.g., from magnet links: "1220..." prefix).
    public init?(multihash: String) {
        // Multihash for SHA-256: 0x12 (SHA-256 function code) 0x20 (32 bytes length)
        guard multihash.count == 68,
              multihash.hasPrefix("1220") else { return nil }
        let hexPart = String(multihash.dropFirst(4))
        guard let hash = InfoHash(hex: hexPart) else { return nil }
        self = hash
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

    // MARK: - Hashable

    public func hash(into hasher: inout Hasher) {
        hasher.combine(bytes)
        hasher.combine(v2Bytes)
    }

    public static func == (lhs: InfoHash, rhs: InfoHash) -> Bool {
        lhs.bytes == rhs.bytes && lhs.v2Bytes == rhs.v2Bytes
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
