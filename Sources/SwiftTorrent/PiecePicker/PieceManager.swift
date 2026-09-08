import Foundation
import CryptoKit

/// Tracks piece completion, block arrivals, and verifies SHA-1 hashes.
public actor PieceManager {
    private let pieceCount: Int
    private let pieceLength: Int
    private let totalSize: Int64
    private let pieceHashes: Data  // concatenated 20-byte SHA-1 hashes
    private var completed: Bitfield
    private var inProgress: Set<Int>
    private var pieceBuffers: [Int: Data]
    private var receivedBlocks: [Int: Set<Int>]  // pieceIndex -> set of block offsets

    public init(info: TorrentInfo) {
        self.pieceCount = info.pieceCount
        self.pieceLength = info.pieceLength
        self.totalSize = info.totalSize
        self.pieceHashes = info.pieces
        self.completed = Bitfield(count: info.pieceCount)
        self.inProgress = []
        self.pieceBuffers = [:]
        self.receivedBlocks = [:]
    }

    /// Mark a piece as being downloaded.
    public func startPiece(_ index: Int) {
        inProgress.insert(index)
        pieceBuffers[index] = Data()
        receivedBlocks[index] = []
    }

    /// Add a block to a piece being downloaded.
    public func addBlock(pieceIndex: Int, offset: Int, data: Data) {
        if pieceBuffers[pieceIndex] == nil {
            startPiece(pieceIndex)
        }
        guard var buffer = pieceBuffers[pieceIndex] else { return }
        let needed = offset + data.count
        if buffer.count < needed {
            buffer.append(Data(count: needed - buffer.count))
        }
        buffer.replaceSubrange(offset..<offset + data.count, with: data)
        pieceBuffers[pieceIndex] = buffer
        receivedBlocks[pieceIndex, default: []].insert(offset)
    }

    /// Check if a specific block has already been received.
    public func isBlockReceived(pieceIndex: Int, offset: Int) -> Bool {
        receivedBlocks[pieceIndex]?.contains(offset) ?? false
    }

    /// Check if all expected blocks for a piece have been received.
    public func areAllBlocksReceived(_ pieceIndex: Int) -> Bool {
        let expectedBlocks = blockCount(for: pieceIndex)
        let count = receivedBlocks[pieceIndex]?.count ?? 0
        return count >= expectedBlocks
    }

    /// Verify and complete a piece.
    public func completePiece(_ index: Int) -> Bool {
        guard areAllBlocksReceived(index) else { return false }
        guard let buffer = pieceBuffers[index] else { return false }

        // Verify hash
        let expectedHash = pieceHashes.subdata(in: index * 20..<(index + 1) * 20)
        let actualHash = Data(Insecure.SHA1.hash(data: buffer))

        guard actualHash == expectedHash else {
            // Hash mismatch — piece is corrupt
            pieceBuffers.removeValue(forKey: index)
            receivedBlocks.removeValue(forKey: index)
            inProgress.remove(index)
            return false
        }

        completed.set(index)
        inProgress.remove(index)
        pieceBuffers.removeValue(forKey: index)
        receivedBlocks.removeValue(forKey: index)
        return true
    }

    /// Get the completed bitfield.
    public func getCompleted() -> Bitfield {
        completed
    }

    /// Check if a piece is complete.
    public func hasPiece(_ index: Int) -> Bool {
        completed.get(index)
    }

    /// Check if all pieces are complete.
    public func isComplete() -> Bool {
        completed.allSet
    }

    /// Get progress as a fraction.
    public func progress() -> Double {
        guard pieceCount > 0 else { return 1.0 }
        return Double(completed.popcount) / Double(pieceCount)
    }

    /// Expected size of a specific piece.
    public func expectedPieceSize(_ index: Int) -> Int {
        let start = Int64(index) * Int64(pieceLength)
        return Int(min(Int64(pieceLength), totalSize - start))
    }

    /// Get the assembled piece data buffer (before completion/verification).
    public func getPieceBuffer(_ index: Int) -> Data? {
        pieceBuffers[index]
    }

    /// Number of 16KB blocks in a piece.
    public func blockCount(for pieceIndex: Int) -> Int {
        let size = expectedPieceSize(pieceIndex)
        return (size + 16383) / 16384
    }

    /// Whether a piece is currently being downloaded.
    public func isInProgress(_ index: Int) -> Bool {
        inProgress.contains(index)
    }

    /// Get all pieces currently in progress.
    public func getInProgress() -> Set<Int> {
        inProgress
    }

    /// The standard piece length for this torrent.
    public func getPieceLength() -> Int {
        pieceLength
    }

    /// Total number of pieces.
    public func getPieceCount() -> Int {
        pieceCount
    }

    /// Mark a piece as already verified and completed (e.g. from resume or disk check).
    public func setPieceCompleted(_ index: Int) {
        guard index >= 0 && index < pieceCount else { return }
        completed.set(index)
        inProgress.remove(index)
        pieceBuffers.removeValue(forKey: index)
        receivedBlocks.removeValue(forKey: index)
    }

    /// Set initial completed bitfield from resume data.
    public func setCompletedBitfield(_ bitfield: Bitfield) {
        for i in 0..<min(pieceCount, bitfield.count) {
            if bitfield.get(i) {
                completed.set(i)
            }
        }
    }

    /// Verify a piece read from disk and mark it completed if valid.
    public func verifyPieceFromDisk(index: Int, data: Data) -> Bool {
        guard index >= 0 && index < pieceCount else { return false }
        let expectedSize = expectedPieceSize(index)
        guard data.count == expectedSize else { return false }

        let expectedHash = pieceHashes.subdata(in: index * 20..<(index + 1) * 20)
        let actualHash = Data(Insecure.SHA1.hash(data: data))
        guard actualHash == expectedHash else { return false }

        setPieceCompleted(index)
        return true
    }

    /// Total bytes of all completed pieces.
    public func completedBytes() -> Int64 {
        var total: Int64 = 0
        for i in 0..<pieceCount {
            if completed.get(i) {
                total += Int64(expectedPieceSize(i))
            }
        }
        return total
    }
}
