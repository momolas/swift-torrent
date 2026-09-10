import Foundation

/// A compact bit array backed by `[UInt64]` for tracking piece availability.
public struct Bitfield: Sendable, Equatable, Hashable {
    public private(set) var storage: [UInt64]
    public let count: Int

    public init(count: Int) {
        self.init(count: count, allSet: false)
    }

    public init(count: Int, allSet: Bool) {
        self.count = count
        let words = (count + 63) / 64
        if !allSet {
            self.storage = [UInt64](repeating: 0, count: words)
        } else {
            var stor = [UInt64](repeating: ~0, count: words)
            // Mask out unused trailing bits in the last word
            let remainder = count % 64
            if remainder != 0 && words > 0 {
                stor[words - 1] = (1 << remainder) - 1
            }
            self.storage = stor
        }
    }

    /// Initialize from raw bytes (network format, big-endian bit ordering).
    public init(data: Data, count: Int) {
        self.count = count
        let words = (count + 63) / 64
        var stor = [UInt64](repeating: 0, count: words)
        for i in 0..<min(data.count * 8, count) {
            let byteIdx = i / 8
            let bitIdx = 7 - (i % 8) // big-endian bit order
            if data[data.startIndex + byteIdx] & (1 << bitIdx) != 0 {
                let wordIdx = i / 64
                let wordBit = i % 64
                stor[wordIdx] |= (1 << wordBit)
            }
        }
        self.storage = stor
    }

    public func get(_ index: Int) -> Bool {
        guard index >= 0 && index < count else { return false }
        let wordIdx = index / 64
        let bitIdx = index % 64
        return storage[wordIdx] & (1 << bitIdx) != 0
    }

    public mutating func set(_ index: Int) {
        guard index >= 0 && index < count else { return }
        let wordIdx = index / 64
        let bitIdx = index % 64
        storage[wordIdx] |= (1 << bitIdx)
    }

    public mutating func clear(_ index: Int) {
        guard index >= 0 && index < count else { return }
        let wordIdx = index / 64
        let bitIdx = index % 64
        storage[wordIdx] &= ~(1 << bitIdx)
    }

    /// Number of set bits.
    public var popcount: Int {
        storage.reduce(0) { $0 + $1.nonzeroBitCount }
    }

    /// Whether all bits are set.
    public var allSet: Bool {
        popcount == count
    }

    /// Whether no bits are set.
    public var isEmpty: Bool {
        popcount == 0
    }

    /// Serialize to bytes (big-endian bit order) for network transmission.
    public func toData() -> Data {
        let byteCount = (count + 7) / 8
        var data = Data(count: byteCount)
        for i in 0..<count {
            if get(i) {
                let byteIdx = i / 8
                let bitIdx = 7 - (i % 8)
                data[byteIdx] |= (1 << bitIdx)
            }
        }
        return data
    }
    /// Convert bitfield to hex string (compatible with ROUGHCOMPUTER format).
    public func toHex() -> String {
        toData().map { byte in
            let hi = byte >> 4
            let lo = byte & 0x0F
            return String(hi, radix: 16) + String(lo, radix: 16)
        }.joined()
    }

    /// Compute completion ratio per cell bucket for UI grid visualization directly from this bitfield.
    public func completion(maxCells: Int) -> [Double] {
        guard count > 0 else { return [] }
        let cells = min(count, max(1, maxCells))
        var sums = [Double](repeating: 0, count: cells)
        var totals = [Double](repeating: 0, count: cells)

        for piece in 0 ..< count {
            let cell = piece * cells / count
            totals[cell] += 1
            if get(piece) {
                sums[cell] += 1
            }
        }

        return (0 ..< cells).map { i in totals[i] > 0 ? sums[i] / totals[i] : 0 }
    }

    /// Compute completion ratio per cell bucket from hex representation.
    public static func completion(hex: String?, count: Int, maxCells: Int) -> [Double] {
        guard count > 0 else { return [] }
        let cells = min(count, max(1, maxCells))
        var sums = [Double](repeating: 0, count: cells)
        var totals = [Double](repeating: 0, count: cells)
        let nibbles = hex.map { h in Array(h.utf8) }

        for piece in 0 ..< count {
            let cell = piece * cells / count
            totals[cell] += 1
            if let nibbles, isSet(piece, in: nibbles) {
                sums[cell] += 1
            }
        }

        return (0 ..< cells).map { i in totals[i] > 0 ? sums[i] / totals[i] : 0 }
    }

    private static func isSet(_ piece: Int, in nibbles: [UInt8]) -> Bool {
        let nibbleIndex = piece / 4
        guard nibbleIndex < nibbles.count else { return false }
        return (hexValue(nibbles[nibbleIndex]) >> (3 - piece % 4)) & 1 == 1
    }

    private static func hexValue(_ ascii: UInt8) -> Int {
        switch ascii {
        case 0x30 ... 0x39: return Int(ascii - 0x30)
        case 0x61 ... 0x66: return Int(ascii - 0x61 + 10)
        case 0x41 ... 0x46: return Int(ascii - 0x41 + 10)
        default: return 0
        }
    }
}
