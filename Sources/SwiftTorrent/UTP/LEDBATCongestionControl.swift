import Foundation

/// LEDBAT (Low Extra Delay Background Transport) congestion control — RFC 6817.
/// Used by uTP to avoid saturating network queues while maximizing throughput.
public struct LEDBATCongestionControl: Sendable {

    // MARK: - Constants

    /// Target queuing delay in microseconds (100 ms as per RFC 6817).
    public static let targetDelay: Int64 = 100_000

    /// Maximum congestion window in bytes.
    public static let maxCWND: Int = 1_048_576  // 1 MB

    /// Minimum congestion window in bytes (one MTU).
    public static let minCWND: Int = 150

    /// Gain factor for LEDBAT.
    public static let gain: Double = 1.0

    // MARK: - State

    /// Current congestion window in bytes.
    public private(set) var cwnd: Int

    /// Slow start threshold (bytes). Below this, CWND grows exponentially.
    public private(set) var ssthresh: Int

    /// Rolling minimum of base delay samples (microseconds).
    /// This tracks the minimum one-way propagation delay.
    public private(set) var baseDelay: Int64

    /// Number of base delay samples collected.
    public private(set) var baseDelaySampleCount: Int

    /// Current one-way delay estimate (microseconds).
    public private(set) var currentDelay: Int64

    /// Number of bytes in flight (sent but not yet acknowledged).
    public private(set) var bytesInFlight: Int

    /// Maximum segment size (payload bytes per packet).
    public let mss: Int

    // MARK: - Initialization

    public init(mss: Int = 1400) {
        self.mss = mss
        self.cwnd = mss * 2  // Initial window = 2 segments
        self.ssthresh = Self.maxCWND
        self.baseDelay = Int64.max
        self.baseDelaySampleCount = 0
        self.currentDelay = 0
        self.bytesInFlight = 0
    }

    // MARK: - Delay Updates

    /// Update delay estimates from a received ACK.
    /// - Parameters:
    ///   - sampleDelay: Measured one-way delay in microseconds from the packet timestamp.
    ///   - bytesAcked: Number of bytes newly acknowledged.
    public mutating func onAck(sampleDelay: Int64, bytesAcked: Int) {
        // Update base delay (rolling minimum)
        if sampleDelay < baseDelay {
            baseDelay = sampleDelay
        }
        baseDelaySampleCount += 1
        currentDelay = sampleDelay

        // Compute queuing delay
        let queuingDelay = Swift.max(0, currentDelay - baseDelay)
        let offTarget = Self.targetDelay - queuingDelay

        // LEDBAT window adjustment
        let scaledGain = Self.gain * Double(offTarget) / Double(Self.targetDelay)
        let delta = Int(scaledGain * Double(bytesAcked) * Double(mss) / Double(Swift.max(cwnd, 1)))

        cwnd = Swift.max(Self.minCWND, Swift.min(Self.maxCWND, cwnd + delta))

        // Decrease bytes in flight
        bytesInFlight = Swift.max(0, bytesInFlight - bytesAcked)
    }

    /// Called when a packet timeout occurs.
    public mutating func onTimeout() {
        ssthresh = Swift.max(cwnd / 2, Self.minCWND * 2)
        cwnd = Self.minCWND
    }

    /// Called when a packet is sent.
    public mutating func onSend(bytes: Int) {
        bytesInFlight += bytes
    }

    /// Check if the window allows sending more data.
    public var canSend: Bool {
        bytesInFlight < cwnd
    }

    /// How many bytes can be sent within the current congestion window.
    public var availableWindow: Int {
        Swift.max(0, cwnd - bytesInFlight)
    }

    /// Current queuing delay in microseconds.
    public var queuingDelay: Int64 {
        guard baseDelay < Int64.max else { return 0 }
        return Swift.max(0, currentDelay - baseDelay)
    }
}
