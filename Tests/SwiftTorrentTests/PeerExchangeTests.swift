import XCTest
@testable import SwiftTorrent

final class PeerExchangeTests: XCTestCase {
    func testCompactPeerEncodingDecoding() {
        let entry = PeerExchange.PeerEntry(address: "192.168.1.100", port: 6881, isSeed: true)
        let compact = PeerExchange.encodeCompactPeer(address: entry.address, port: entry.port)
        XCTAssertNotNil(compact)
        XCTAssertEqual(compact?.count, 6)

        let parsed = PeerExchange.parseCompactPeers(compact!, flags: Data([PeerExchange.flagSeed]))
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].address, "192.168.1.100")
        XCTAssertEqual(parsed[0].port, 6881)
        XCTAssertTrue(parsed[0].isSeed)
    }

    func testEncodeDecodePEXPayload() {
        let added = [
            PeerExchange.PeerEntry(address: "1.2.3.4", port: 51413, isSeed: false),
            PeerExchange.PeerEntry(address: "5.6.7.8", port: 6881, isSeed: true)
        ]
        let dropped = [
            PeerExchange.PeerEntry(address: "9.10.11.12", port: 8080, isSeed: false)
        ]

        let encoded = PeerExchange.encode(added: added, dropped: dropped)
        XCTAssertFalse(encoded.isEmpty)

        let decoded = PeerExchange.decode(payload: encoded)
        XCTAssertEqual(decoded.added.count, 2)
        XCTAssertEqual(decoded.added[0].address, "1.2.3.4")
        XCTAssertEqual(decoded.added[0].port, 51413)
        XCTAssertFalse(decoded.added[0].isSeed)

        XCTAssertEqual(decoded.added[1].address, "5.6.7.8")
        XCTAssertEqual(decoded.added[1].port, 6881)
        XCTAssertTrue(decoded.added[1].isSeed)

        XCTAssertEqual(decoded.dropped.count, 1)
        XCTAssertEqual(decoded.dropped[0].address, "9.10.11.12")
        XCTAssertEqual(decoded.dropped[0].port, 8080)
    }

    func testPEXTruncationTo50Peers() {
        var added: [PeerExchange.PeerEntry] = []
        for i in 1...60 {
            added.append(PeerExchange.PeerEntry(address: "10.0.0.\(i)", port: UInt16(1000 + i)))
        }

        let encoded = PeerExchange.encode(added: added, dropped: [])
        let decoded = PeerExchange.decode(payload: encoded)

        // Per BEP-11, payload should be capped to 50 peers
        XCTAssertEqual(decoded.added.count, 50)
    }
}
