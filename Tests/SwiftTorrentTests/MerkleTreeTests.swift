import XCTest
@testable import SwiftTorrent

final class MerkleTreeTests: XCTestCase {
    func testSingleLeafRoot() {
        let block = Data(repeating: 0x41, count: 16384)
        let tree = MerkleTree(fileData: block)

        XCTAssertEqual(tree.leafCount, 1)
        XCTAssertEqual(tree.rootHash.count, 32)
        XCTAssertEqual(tree.rootHash, tree.leafHashes[0])
    }

    func testPowerOfTwoLeaves() {
        // 4 blocks = 64 KiB
        let fileData = Data((0..<65536).map { UInt8($0 & 0xFF) })
        let tree = MerkleTree(fileData: fileData)

        XCTAssertEqual(tree.leafCount, 4)
        XCTAssertEqual(tree.rootHash.count, 32)

        // Verify proofs for all 4 leaves
        for i in 0..<4 {
            let proof = tree.proof(forLeafAt: i)
            XCTAssertEqual(proof.count, 2) // log2(4) = 2 proof hashes

            let isValid = MerkleTree.verify(
                leafHash: tree.leafHashes[i],
                at: i,
                proof: proof,
                root: tree.rootHash,
                leafCount: 4
            )
            XCTAssertTrue(isValid, "Proof for leaf \(i) should be valid")
        }
    }

    func testNonPowerOfTwoLeavesPadding() {
        // 3 blocks = 48 KiB -> tree will pad to 4 leaves with zero hashes
        let fileData = Data((0..<49152).map { UInt8($0 & 0xFF) })
        let tree = MerkleTree(fileData: fileData)

        XCTAssertEqual(tree.leafCount, 3)
        XCTAssertEqual(tree.rootHash.count, 32)

        // All 3 real leaves must verify
        for i in 0..<3 {
            let proof = tree.proof(forLeafAt: i)
            let isValid = MerkleTree.verify(
                leafHash: tree.leafHashes[i],
                at: i,
                proof: proof,
                root: tree.rootHash,
                leafCount: 3
            )
            XCTAssertTrue(isValid, "Proof for leaf \(i) in padded tree should be valid")
        }
    }

    func testTamperedProofFails() {
        let fileData = Data((0..<65536).map { UInt8($0 & 0xFF) })
        let tree = MerkleTree(fileData: fileData)

        var proof = tree.proof(forLeafAt: 0)
        XCTAssertFalse(proof.isEmpty)

        // Tamper with proof hash
        proof[0][0] ^= 0xFF

        let isValid = MerkleTree.verify(
            leafHash: tree.leafHashes[0],
            at: 0,
            proof: proof,
            root: tree.rootHash,
            leafCount: 4
        )
        XCTAssertFalse(isValid, "Tampered proof must fail verification")
    }

    func testTamperedLeafFails() {
        let fileData = Data((0..<65536).map { UInt8($0 & 0xFF) })
        let tree = MerkleTree(fileData: fileData)

        let proof = tree.proof(forLeafAt: 1)
        var tamperedLeaf = tree.leafHashes[1]
        tamperedLeaf[0] ^= 0x42

        let isValid = MerkleTree.verify(
            leafHash: tamperedLeaf,
            at: 1,
            proof: proof,
            root: tree.rootHash,
            leafCount: 4
        )
        XCTAssertFalse(isValid, "Tampered leaf hash must fail verification")
    }
}
