import Foundation
import CryptoKit

/// SHA-256 Merkle tree for BEP 52 (BitTorrent v2).
/// Leaves are 16 KiB blocks; the root hash is the file's "pieces root".
public struct MerkleTree: Sendable, Equatable {

    /// Standard leaf block size for BEP 52 (16 KiB).
    public static let blockSize = 16384

    /// SHA-256 hash of an empty leaf (padding node).
    public static let emptyLeafHash: Data = {
        Data(SHA256.hash(data: Data()))
    }()

    /// All node hashes in the tree, stored in level-order.
    /// Level 0 = root, last level = leaves.
    public let nodes: [Data]

    /// Number of leaves (original, not padded).
    public let leafCount: Int

    /// The root hash (32 bytes).
    public var root: Data {
        nodes.isEmpty ? Self.emptyLeafHash : nodes[0]
    }

    /// Root hash convenience alias.
    public var rootHash: Data { root }

    /// Leaf hashes (original unpadded leaves).
    public var leafHashes: [Data] {
        let levels = reconstructLevels()
        guard let leaves = levels.last else { return [] }
        return Array(leaves.prefix(leafCount))
    }

    // MARK: - Construction

    /// Build a Merkle tree from file data, using 16 KiB leaf blocks.
    public init(fileData: Data) {
        var leafHashes: [Data] = []
        var offset = 0
        while offset < fileData.count {
            let end = Swift.min(offset + Self.blockSize, fileData.count)
            let block = fileData[offset..<end]
            let hash = Data(SHA256.hash(data: block))
            leafHashes.append(hash)
            offset = end
        }

        if leafHashes.isEmpty {
            leafHashes.append(Self.emptyLeafHash)
        }

        self.leafCount = leafHashes.count
        self.nodes = Self.buildTree(leaves: leafHashes)
    }

    /// Build from pre-computed leaf hashes.
    public init(leafHashes: [Data]) {
        var leaves = leafHashes
        if leaves.isEmpty {
            leaves.append(Self.emptyLeafHash)
        }
        self.leafCount = leaves.count
        self.nodes = Self.buildTree(leaves: leaves)
    }

    // MARK: - Tree Construction

    /// Build the complete binary Merkle tree from leaf hashes.
    /// Returns nodes in level-order (root first).
    private static func buildTree(leaves: [Data]) -> [Data] {
        // Pad to next power of 2
        let paddedCount = nextPowerOf2(leaves.count)
        var currentLevel = leaves
        while currentLevel.count < paddedCount {
            currentLevel.append(emptyLeafHash)
        }

        var levels: [[Data]] = [currentLevel]

        // Build from leaves up to root
        while currentLevel.count > 1 {
            var parentLevel: [Data] = []
            for i in stride(from: 0, to: currentLevel.count, by: 2) {
                let left = currentLevel[i]
                let right = i + 1 < currentLevel.count ? currentLevel[i + 1] : emptyLeafHash
                let combined = left + right
                parentLevel.append(Data(SHA256.hash(data: combined)))
            }
            levels.append(parentLevel)
            currentLevel = parentLevel
        }

        // Reverse to get root first (level-order)
        levels.reverse()
        return levels.flatMap { $0 }
    }

    // MARK: - Proof Generation

    /// Generate a Merkle proof (audit path) for the leaf at the given index.
    /// Returns sibling hashes from leaf to root.
    public func proof(forLeafAt index: Int) -> [Data] {
        let paddedCount = Self.nextPowerOf2(leafCount)
        guard index < paddedCount else { return [] }

        // Reconstruct levels
        let levels = reconstructLevels()
        var proofHashes: [Data] = []
        var idx = index

        // Walk from leaf level up to root
        let leafLevel = levels.count - 1
        for level in stride(from: leafLevel, to: 0, by: -1) {
            let siblingIdx = idx ^ 1  // XOR with 1 to get sibling
            if siblingIdx < levels[level].count {
                proofHashes.append(levels[level][siblingIdx])
            }
            idx /= 2
        }

        return proofHashes
    }

    /// Verify that a leaf hash at the given index matches the root using the proof.
    public static func verify(
        leafHash: Data,
        at index: Int,
        proof: [Data],
        root: Data,
        leafCount: Int
    ) -> Bool {
        var hash = leafHash
        var idx = index

        for sibling in proof {
            let combined: Data
            if idx % 2 == 0 {
                combined = hash + sibling
            } else {
                combined = sibling + hash
            }
            hash = Data(SHA256.hash(data: combined))
            idx /= 2
        }

        return hash == root
    }

    // MARK: - Helpers

    private func reconstructLevels() -> [[Data]] {
        let paddedCount = Self.nextPowerOf2(leafCount)
        let depth = Int(log2(Double(paddedCount))) + 1

        var levels: [[Data]] = []
        var offset = 0
        var levelSize = 1  // root level has 1 node

        for _ in 0..<depth {
            let end = Swift.min(offset + levelSize, nodes.count)
            if offset < end {
                levels.append(Array(nodes[offset..<end]))
            }
            offset = end
            levelSize *= 2
        }

        return levels
    }

    public static func nextPowerOf2(_ n: Int) -> Int {
        guard n > 0 else { return 1 }
        var v = n - 1
        v |= v >> 1
        v |= v >> 2
        v |= v >> 4
        v |= v >> 8
        v |= v >> 16
        v |= v >> 32
        return v + 1
    }
}
