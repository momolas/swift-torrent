import Foundation

/// Rarest-first piece selection strategy with sequential streaming priority.
public struct PiecePicker: Sendable {
    private let pieceCount: Int
    private var availability: [Int]  // how many peers have each piece
    public var sequentialEngine: SequentialStreamEngine?

    public init(pieceCount: Int, isStreaming: Bool = false) {
        self.pieceCount = pieceCount
        self.availability = [Int](repeating: 0, count: pieceCount)
        if isStreaming {
            self.sequentialEngine = SequentialStreamEngine(totalPieces: pieceCount)
        }
    }

    /// Configures or updates sequential streaming mode.
    public mutating func setSequentialStreaming(enabled: Bool, currentPlaybackPiece: Int = 0) {
        if enabled {
            self.sequentialEngine = SequentialStreamEngine(
                totalPieces: pieceCount,
                currentPlaybackPiece: currentPlaybackPiece
            )
        } else {
            self.sequentialEngine = nil
        }
    }

    /// Update availability from a peer's bitfield.
    public mutating func addPeerBitfield(_ bitfield: Bitfield) {
        for i in 0..<min(pieceCount, bitfield.count) {
            if bitfield.get(i) {
                availability[i] += 1
            }
        }
    }

    /// Remove a peer's bitfield from availability counts.
    public mutating func removePeerBitfield(_ bitfield: Bitfield) {
        for i in 0..<min(pieceCount, bitfield.count) {
            if bitfield.get(i) {
                availability[i] = max(0, availability[i] - 1)
            }
        }
    }

    /// Increment availability for a single piece (peer sent "have").
    public mutating func addHave(_ pieceIndex: Int) {
        guard pieceIndex >= 0 && pieceIndex < pieceCount else { return }
        availability[pieceIndex] += 1
    }

    /// Pick the next piece to request using rarest-first strategy (or sequential if streaming).
    /// `have` is our own bitfield; `peerHas` is the peer's bitfield.
    public func pick(have: Bitfield, peerHas: Bitfield) -> Int? {
        if let engine = sequentialEngine {
            var candidates: [Int] = []
            for i in 0..<pieceCount {
                if !have.get(i) && peerHas.get(i) {
                    candidates.append(i)
                }
            }
            guard !candidates.isEmpty else { return nil }
            return candidates.min { a, b in
                let prioA = engine.priority(for: a)
                let prioB = engine.priority(for: b)
                if prioA == prioB {
                    return availability[a] < availability[b]
                }
                return prioA < prioB
            }
        }

        var best: Int?
        var bestAvail = Int.max

        for i in 0..<pieceCount {
            // We don't have it, peer does have it
            if !have.get(i) && peerHas.get(i) {
                if availability[i] < bestAvail {
                    bestAvail = availability[i]
                    best = i
                }
            }
        }

        return best
    }

    /// Pick multiple pieces (for pipelining).
    public func pickMultiple(have: Bitfield, peerHas: Bitfield, count: Int) -> [Int] {
        var candidates: [(index: Int, avail: Int)] = []
        for i in 0..<pieceCount {
            if !have.get(i) && peerHas.get(i) {
                candidates.append((i, availability[i]))
            }
        }

        if let engine = sequentialEngine {
            candidates.sort { a, b in
                let prioA = engine.priority(for: a.index)
                let prioB = engine.priority(for: b.index)
                if prioA == prioB {
                    return a.avail < b.avail
                }
                return prioA < prioB
            }
        } else {
            candidates.sort { $0.avail < $1.avail }
        }

        return Array(candidates.prefix(count).map(\.index))
    }
}
