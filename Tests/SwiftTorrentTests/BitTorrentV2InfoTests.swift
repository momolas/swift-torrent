import XCTest
@testable import SwiftTorrent

final class BitTorrentV2InfoTests: XCTestCase {
    func testInfoHashV2Generation() {
        let dummyInfo = Data("d4:name8:test.txt12:piece lengthi16384ee".utf8)
        let hash = InfoHash.v2(from: dummyInfo)

        XCTAssertEqual(hash.version, .v2)
        XCTAssertEqual(hash.bytes.count, 32)
        XCTAssertEqual(hash.hex.count, 64)
    }

    func testInfoHashHybridGeneration() {
        let dummyInfo = Data("d4:name10:hybrid.iso12:piece lengthi65536ee".utf8)
        let hybrid = InfoHash.hybrid(from: dummyInfo)

        XCTAssertEqual(hybrid.version, .hybrid)
        XCTAssertEqual(hybrid.bytes.count, 20) // Primary v1 backward-compatible hash
        XCTAssertEqual(hybrid.v2Bytes?.count, 32)
        XCTAssertNotNil(hybrid.v2Hex)
        XCTAssertEqual(hybrid.v2Hex?.count, 64)
    }

    func testInfoHashMultihash() {
        let dummyInfo = Data("multihash test data".utf8)
        let v2 = InfoHash.v2(from: dummyInfo)

        let multihashStr = "1220" + v2.hex
        let parsed = InfoHash(multihash: multihashStr)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.version, .v2)
        XCTAssertEqual(parsed?.bytes, v2.bytes)
    }

    func testBEP52HashRequestMessageRoundTrip() throws {
        let root = Data(repeating: 0x55, count: 32)
        let msg = PeerMessage.hashRequest(
            piecesRoot: root,
            baseLayer: 2,
            index: 10,
            length: 4,
            proofLayers: 3
        )

        let encoded = msg.encode()
        // 4 (len) + 1 (id) + 32 (root) + 2 + 4 + 4 + 2 = 45 + 4 = 49 bytes total
        XCTAssertEqual(encoded.count, 53)

        let decoded = try PeerMessage.decode(from: Data(encoded.dropFirst(4)))
        guard case let .hashRequest(piecesRoot, baseLayer, index, length, proofLayers) = decoded else {
            return XCTFail("Expected .hashRequest, got \(String(describing: decoded))")
        }

        XCTAssertEqual(piecesRoot, root)
        XCTAssertEqual(baseLayer, 2)
        XCTAssertEqual(index, 10)
        XCTAssertEqual(length, 4)
        XCTAssertEqual(proofLayers, 3)
    }

    func testBEP52HashesMessageRoundTrip() throws {
        let root = Data(repeating: 0xAA, count: 32)
        let hashesData = Data(repeating: 0xBB, count: 64) // Two 32-byte hashes
        let msg = PeerMessage.hashes(
            piecesRoot: root,
            baseLayer: 0,
            index: 0,
            length: 2,
            proofLayers: 1,
            hashes: hashesData
        )

        let encoded = msg.encode()
        let decoded = try PeerMessage.decode(from: Data(encoded.dropFirst(4)))
        guard case let .hashes(piecesRoot, baseLayer, index, length, proofLayers, hashes) = decoded else {
            return XCTFail("Expected .hashes, got \(String(describing: decoded))")
        }

        XCTAssertEqual(piecesRoot, root)
        XCTAssertEqual(baseLayer, 0)
        XCTAssertEqual(index, 0)
        XCTAssertEqual(length, 2)
        XCTAssertEqual(proofLayers, 1)
        XCTAssertEqual(hashes, hashesData)
    }

    func testBEP52HashRejectMessageRoundTrip() throws {
        let root = Data(repeating: 0xEE, count: 32)
        let msg = PeerMessage.hashReject(
            piecesRoot: root,
            baseLayer: 1,
            index: 5,
            length: 8,
            proofLayers: 2
        )

        let encoded = msg.encode()
        let decoded = try PeerMessage.decode(from: Data(encoded.dropFirst(4)))
        guard case let .hashReject(piecesRoot, baseLayer, index, length, proofLayers) = decoded else {
            return XCTFail("Expected .hashReject, got \(String(describing: decoded))")
        }

        XCTAssertEqual(piecesRoot, root)
        XCTAssertEqual(baseLayer, 1)
        XCTAssertEqual(index, 5)
        XCTAssertEqual(length, 8)
        XCTAssertEqual(proofLayers, 2)
    }

    func testV2FileEntryRepresentation() {
        let rootHash = Data(repeating: 0x11, count: 32)
        let entry = TorrentInfo.V2FileEntry(
            path: "docs/manual.pdf",
            length: 1_048_576,
            piecesRoot: rootHash
        )

        XCTAssertEqual(entry.path, "docs/manual.pdf")
        XCTAssertEqual(entry.length, 1_048_576)
        XCTAssertEqual(entry.piecesRoot, rootHash)
    }
}
