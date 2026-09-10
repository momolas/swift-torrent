import XCTest
@testable import SwiftTorrent

final class PrivateTorrentTests: XCTestCase {
    func testHandshakeClearsDHTWhenPrivate() {
        // When a torrent is marked private, the DHT bit in handshake reserved bytes MUST be 0
        let reservedPrivate = Handshake.defaultReserved(enableFastExtension: true, enableDHT: true, isPrivate: true)
        let hsPrivate = Handshake(
            infoHash: Data(repeating: 1, count: 20),
            peerID: Data(repeating: 2, count: 20),
            reserved: reservedPrivate
        )
        XCTAssertFalse(hsPrivate.supportsDHT, "DHT bit must NOT be set when isPrivate is true")
        XCTAssertTrue(hsPrivate.supportsFastExtension, "Fast Extension should still be enabled on private torrents")

        let reservedPublic = Handshake.defaultReserved(enableFastExtension: true, enableDHT: true, isPrivate: false)
        let hsPublic = Handshake(
            infoHash: Data(repeating: 1, count: 20),
            peerID: Data(repeating: 2, count: 20),
            reserved: reservedPublic
        )
        XCTAssertTrue(hsPublic.supportsDHT, "DHT bit must be set when isPrivate is false and DHT is enabled")
    }

    func testPeerConnectionDisablesDHTForPrivate() {
        let conn = PeerConnection(
            address: "127.0.0.1",
            port: 6881,
            infoHash: Data(repeating: 1, count: 20),
            peerID: Data(repeating: 2, count: 20),
            isPrivate: true,
            enableFastExtension: true,
            enableDHT: true
        )
        XCTAssertTrue(conn.isPrivate)
        XCTAssertFalse(conn.supportsDHT)
    }

    func testTorrentStatusReflectsIsPrivate() {
        let status = TorrentStatus(
            infoHash: InfoHash.v1(from: Data(repeating: 0x55, count: 20)),
            name: "Private Swarm",
            state: .downloading,
            progress: 0.5,
            downloadRate: 1000,
            uploadRate: 500,
            totalDownloaded: 5000,
            totalUploaded: 2500,
            totalSize: 10000,
            numPeers: 5,
            numSeeds: 2,
            piecesCompleted: 5,
            piecesTotal: 10,
            isStreaming: false,
            isPrivate: true
        )
        XCTAssertTrue(status.isPrivate)
    }

    func testTorrentInfoParsesPrivateFlag() throws {
        // Build a sample .torrent bencoded dictionary with private = 1
        let infoDict: [(key: Data, value: BencodeValue)] = [
            (key: Data("name".utf8), value: .string(Data("test.bin".utf8))),
            (key: Data("piece length".utf8), value: .integer(16384)),
            (key: Data("pieces".utf8), value: .string(Data(repeating: 0xAA, count: 20))),
            (key: Data("length".utf8), value: .integer(16384)),
            (key: Data("private".utf8), value: .integer(1))
        ]
        let rootDict: [(key: Data, value: BencodeValue)] = [
            (key: Data("info".utf8), value: .dictionary(infoDict))
        ]
        let torrentData = BencodeEncoder().encode(.dictionary(rootDict))
        let info = try TorrentInfo.parse(from: torrentData)
        XCTAssertTrue(info.isPrivate, "TorrentInfo must parse private = 1 as isPrivate == true")
    }
}
