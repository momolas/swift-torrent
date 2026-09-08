import Foundation

/// Prioritizes piece selection for video streaming playback.
/// Prioritizes container headers (first 2%), container index tables (last 2%),
/// and sequential pieces following the current playback position.
public struct SequentialStreamEngine: Sendable {
    public let totalPieces: Int
    public var currentPlaybackPiece: Int
    public let bufferWindowPieces: Int

    public init(totalPieces: Int, currentPlaybackPiece: Int = 0, bufferWindowPieces: Int = 10) {
        self.totalPieces = max(1, totalPieces)
        self.currentPlaybackPiece = max(0, min(currentPlaybackPiece, totalPieces - 1))
        self.bufferWindowPieces = max(3, bufferWindowPieces)
    }

    /// Determines priority score for a given piece index.
    /// Lower score = higher priority.
    public func priority(for pieceIndex: Int) -> Int {
        guard pieceIndex >= 0 && pieceIndex < totalPieces else { return Int.max }

        // 1. First 2% pieces: container header (moov atom, mkv ebml header)
        let headerBoundary = max(2, totalPieces / 50)
        if pieceIndex < headerBoundary {
            return pieceIndex // highest priority: 0 ..< headerBoundary
        }

        // 2. Last 2% pieces: index table / seek table / metadata footer
        let footerBoundary = max(0, totalPieces - max(2, totalPieces / 50))
        if pieceIndex >= footerBoundary {
            return 100 + (totalPieces - pieceIndex) // second priority: 100..
        }

        // 3. Sequential pieces from current playback position (playback window)
        if pieceIndex >= currentPlaybackPiece && pieceIndex < (currentPlaybackPiece + bufferWindowPieces) {
            return 200 + (pieceIndex - currentPlaybackPiece) // third priority: 200..
        }

        // 4. Remaining pieces in chronological sequence
        if pieceIndex >= currentPlaybackPiece {
            return 1_000 + (pieceIndex - currentPlaybackPiece)
        } else {
            // Already passed pieces or earlier
            return 10_000 + pieceIndex
        }
    }

    /// Sorts available piece candidates by streaming priority.
    public func sortedCandidates(_ candidates: [Int]) -> [Int] {
        candidates.sorted { priority(for: $0) < priority(for: $1) }
    }
}
