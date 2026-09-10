import Foundation
import CryptoKit

/// BEP-6 Fast Extension algorithms and utilities.
public enum FastExtension {
    /// Generate the canonical Allowed Fast set as specified in BEP-6.
    ///
    /// - Parameters:
    ///   - k: Desired number of pieces in the fast set (typically 10).
    ///   - pieceCount: Total number of pieces in the torrent (`sz`).
    ///   - infoHash: 20-byte torrent infohash.
    ///   - ip: IPv4 address string (e.g. "192.168.1.50").
    /// - Returns: An array of piece indices forming the Allowed Fast set.
    public static func generateFastSet(k: Int, pieceCount: Int, infoHash: Data, ip: String) -> [Int] {
        guard pieceCount > 0, k > 0 else { return [] }
        let targetCount = min(k, pieceCount)
        guard let ipInt = parseIPv4(ip) else { return [] }

        var result: [Int] = []
        result.reserveCapacity(targetCount)

        // Mask IP with 0xFFFFFF00
        let maskedIP = ipInt & 0xFFFFFF00
        var seed = Data(count: 4)
        seed[0] = UInt8((maskedIP >> 24) & 0xFF)
        seed[1] = UInt8((maskedIP >> 16) & 0xFF)
        seed[2] = UInt8((maskedIP >> 8) & 0xFF)
        seed[3] = UInt8(maskedIP & 0xFF)

        // Append 20-byte infohash
        var x = seed + infoHash.prefix(20)

        while result.count < targetCount {
            let digest = Insecure.SHA1.hash(data: x)
            let digestData = Data(digest)
            x = digestData

            for i in 0..<5 {
                guard result.count < targetCount else { break }
                let offset = i * 4
                guard offset + 4 <= digestData.count else { break }
                let y = digestData.readUInt32BE(at: offset)
                let index = Int(y % UInt32(pieceCount))
                if !result.contains(index) {
                    result.append(index)
                }
            }
        }

        return result
    }

    /// Parse an IPv4 string "a.b.c.d" into a 32-bit unsigned integer in host byte order.
    public static func parseIPv4(_ ip: String) -> UInt32? {
        let parts = ip.split(separator: ".")
        guard parts.count == 4 else { return nil }
        var result: UInt32 = 0
        for part in parts {
            guard let val = UInt8(part) else { return nil }
            result = (result << 8) | UInt32(val)
        }
        return result
    }
}
