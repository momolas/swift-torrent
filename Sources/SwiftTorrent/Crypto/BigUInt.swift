import Foundation

/// Lightweight pure Swift arbitrary precision unsigned integer for 768-bit Diffie-Hellman calculations.
public struct BigUInt: Equatable, Comparable, Sendable {
    // Stored in little-endian order: words[0] is the least significant 64-bit word.
    public var words: [UInt64]

    public init() {
        self.words = [0]
    }

    public init(words: [UInt64]) {
        var w = words
        while w.count > 1 && w.last == 0 {
            w.removeLast()
        }
        self.words = w.isEmpty ? [0] : w
    }

    public init(_ value: UInt64) {
        self.words = [value]
    }

    public init?(hex: String) {
        var cleanHex = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanHex.hasPrefix("0x") || cleanHex.hasPrefix("0X") {
            cleanHex = String(cleanHex.dropFirst(2))
        }
        guard !cleanHex.isEmpty else { return nil }

        let remainder = cleanHex.count % 16
        if remainder != 0 {
            cleanHex = String(repeating: "0", count: 16 - remainder) + cleanHex
        }

        var words: [UInt64] = []
        var endIndex = cleanHex.endIndex
        while endIndex > cleanHex.startIndex {
            let startIndex = cleanHex.index(endIndex, offsetBy: -16)
            let chunk = String(cleanHex[startIndex..<endIndex])
            guard let word = UInt64(chunk, radix: 16) else { return nil }
            words.append(word)
            endIndex = startIndex
        }

        self.init(words: words)
    }

    public init(bigEndian data: Data) {
        guard !data.isEmpty else {
            self.init(0)
            return
        }

        var words: [UInt64] = []
        var i = data.count
        while i > 0 {
            let start = Swift.max(0, i - 8)
            var word: UInt64 = 0
            for byte in data[start..<i] {
                word = (word << 8) | UInt64(byte)
            }
            words.append(word)
            i = start
        }
        self.init(words: words)
    }

    /// Export as big-endian Data, zero-padded to the specified length.
    public func toData(paddedToLength targetLength: Int = 96) -> Data {
        var bytes = [UInt8]()
        for word in words {
            for b in 0..<8 {
                bytes.append(UInt8((word >> (b * 8)) & 0xFF))
            }
        }
        while bytes.count > 1 && bytes.last == 0 {
            bytes.removeLast()
        }
        bytes.reverse()

        if bytes.count < targetLength {
            let padding = [UInt8](repeating: 0, count: targetLength - bytes.count)
            return Data(padding + bytes)
        } else if bytes.count > targetLength {
            return Data(bytes.suffix(targetLength))
        } else {
            return Data(bytes)
        }
    }

    public static func < (lhs: BigUInt, rhs: BigUInt) -> Bool {
        if lhs.words.count != rhs.words.count {
            return lhs.words.count < rhs.words.count
        }
        for i in stride(from: lhs.words.count - 1, through: 0, by: -1) {
            if lhs.words[i] != rhs.words[i] {
                return lhs.words[i] < rhs.words[i]
            }
        }
        return false
    }

    public static func == (lhs: BigUInt, rhs: BigUInt) -> Bool {
        lhs.words == rhs.words
    }

    public static func + (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        var result = [UInt64]()
        let maxCount = Swift.max(lhs.words.count, rhs.words.count)
        var carry: UInt64 = 0

        for i in 0..<maxCount {
            let a = i < lhs.words.count ? lhs.words[i] : 0
            let b = i < rhs.words.count ? rhs.words[i] : 0

            let (sum1, overflow1) = a.addingReportingOverflow(b)
            let (sum2, overflow2) = sum1.addingReportingOverflow(carry)
            carry = (overflow1 ? 1 : 0) + (overflow2 ? 1 : 0)
            result.append(sum2)
        }
        if carry > 0 {
            result.append(carry)
        }
        return BigUInt(words: result)
    }

    public static func - (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        precondition(lhs >= rhs, "BigUInt subtraction underflow")
        var result = [UInt64]()
        var borrow: UInt64 = 0

        for i in 0..<lhs.words.count {
            let a = lhs.words[i]
            let b = i < rhs.words.count ? rhs.words[i] : 0

            let (diff1, overflow1) = a.subtractingReportingOverflow(b)
            let (diff2, overflow2) = diff1.subtractingReportingOverflow(borrow)
            borrow = (overflow1 ? 1 : 0) + (overflow2 ? 1 : 0)
            result.append(diff2)
        }
        return BigUInt(words: result)
    }

    public static func * (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        if lhs == BigUInt(0) || rhs == BigUInt(0) { return BigUInt(0) }
        var result = [UInt64](repeating: 0, count: lhs.words.count + rhs.words.count)

        for i in 0..<lhs.words.count {
            var carry: UInt64 = 0
            for j in 0..<rhs.words.count {
                let (high, low) = lhs.words[i].multipliedFullWidth(by: rhs.words[j])
                let (sum1, ov1) = result[i + j].addingReportingOverflow(low)
                let (sum2, ov2) = sum1.addingReportingOverflow(carry)
                carry = high + (ov1 ? 1 : 0) + (ov2 ? 1 : 0)
                result[i + j] = sum2
            }
            if carry > 0 {
                result[i + rhs.words.count] += carry
            }
        }
        return BigUInt(words: result)
    }

    public static func / (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        let (q, _) = lhs.quotientAndRemainder(dividingBy: rhs)
        return q
    }

    public static func % (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        let (_, r) = lhs.quotientAndRemainder(dividingBy: rhs)
        return r
    }

    public func quotientAndRemainder(dividingBy rhs: BigUInt) -> (quotient: BigUInt, remainder: BigUInt) {
        precondition(rhs != BigUInt(0), "Division by zero")
        if self < rhs { return (BigUInt(0), self) }
        if rhs == self { return (BigUInt(1), BigUInt(0)) }

        let totalBits = self.bitWidth
        var quotient = BigUInt(0)
        var remainder = BigUInt(0)

        for i in stride(from: totalBits - 1, through: 0, by: -1) {
            remainder = remainder.shiftedLeftByOne()
            if self.isBitSet(at: i) {
                remainder.setBit(at: 0)
            }
            if remainder >= rhs {
                remainder = remainder - rhs
                quotient.setBit(at: i)
            }
        }
        return (quotient, remainder)
    }

    public var bitWidth: Int {
        guard let last = words.last, last > 0 else { return 0 }
        return (words.count - 1) * 64 + (64 - last.leadingZeroBitCount)
    }

    public func isBitSet(at index: Int) -> Bool {
        let wordIdx = index / 64
        let bitIdx = index % 64
        guard wordIdx < words.count else { return false }
        return (words[wordIdx] & (1 << bitIdx)) != 0
    }

    public mutating func setBit(at index: Int) {
        let wordIdx = index / 64
        let bitIdx = index % 64
        while words.count <= wordIdx {
            words.append(0)
        }
        words[wordIdx] |= (1 << bitIdx)
    }

    public func shiftedLeftByOne() -> BigUInt {
        var result = [UInt64]()
        var carry: UInt64 = 0
        for w in words {
            let newCarry = w >> 63
            result.append((w << 1) | carry)
            carry = newCarry
        }
        if carry > 0 {
            result.append(carry)
        }
        return BigUInt(words: result)
    }

    /// Modular exponentiation using binary method: (self ^ exponent) mod modulus
    public func power(_ exponent: BigUInt, modulus: BigUInt) -> BigUInt {
        precondition(modulus > BigUInt(0), "Modulus must be positive")
        if modulus == BigUInt(1) { return BigUInt(0) }

        var result = BigUInt(1)
        var base = self % modulus
        let expBits = exponent.bitWidth

        for i in 0..<expBits {
            if exponent.isBitSet(at: i) {
                result = (result * base) % modulus
            }
            base = (base * base) % modulus
        }
        return result
    }
}
