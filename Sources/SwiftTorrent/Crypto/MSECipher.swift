import Foundation

/// ARC4 / RC4 stream cipher conforming to BitTorrent MSE specification (drop1024).
public final class MSECipher: @unchecked Sendable {
    private var s: [UInt8]
    private var i: Int = 0
    private var j: Int = 0

    /// Initialize with key and discard the specified number of initial keystream bytes.
    /// BitTorrent MSE specifies discarding the first 1024 bytes to prevent FMS key recovery.
    public init(key: Data, discardBytes: Int = 1024) {
        // Key-scheduling algorithm (KSA)
        var state = [UInt8](repeating: 0, count: 256)
        for idx in 0..<256 {
            state[idx] = UInt8(idx)
        }

        var jIndex = 0
        let keyCount = key.count
        for idx in 0..<256 {
            let keyByte = key[key.startIndex + (idx % keyCount)]
            jIndex = (jIndex + Int(state[idx]) + Int(keyByte)) & 0xFF
            state.swapAt(idx, jIndex)
        }

        self.s = state
        self.i = 0
        self.j = 0

        // Discard initial keystream bytes
        if discardBytes > 0 {
            var discard = [UInt8](repeating: 0, count: discardBytes)
            process(&discard)
        }
    }

    /// Process (encrypt or decrypt) a byte array in place (XOR with keystream).
    public func process(_ buffer: inout [UInt8]) {
        for idx in 0..<buffer.count {
            i = (i + 1) & 0xFF
            j = (j + Int(s[i])) & 0xFF
            s.swapAt(i, j)
            let k = s[(Int(s[i]) + Int(s[j])) & 0xFF]
            buffer[idx] ^= k
        }
    }

    /// Process a Data object and return the result.
    public func process(_ data: Data) -> Data {
        var copy = [UInt8](data)
        process(&copy)
        return Data(copy)
    }
}
