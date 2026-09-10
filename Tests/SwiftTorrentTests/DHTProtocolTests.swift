import XCTest
@testable import SwiftTorrent

final class DHTProtocolTests: XCTestCase {
    func testHandshakeDHTBitNegotiation() {
        let reservedWithDHT = Handshake.defaultReserved(enableFastExtension: false, enableDHT: true, isPrivate: false)
        let hs = Handshake(
            infoHash: Data(repeating: 0x33, count: 20),
            peerID: Data(repeating: 0x44, count: 20),
            reserved: reservedWithDHT
        )
        XCTAssertTrue(hs.supportsDHT)
        XCTAssertEqual(reservedWithDHT[7] & 0x01, 0x01)
    }

    func testPortMessageEncodingDecoding() throws {
        let portMsg = PeerMessage.port(6881)
        let encoded = portMsg.encode()
        XCTAssertEqual(encoded.count, 7) // 4 length + 1 id + 2 port
        XCTAssertEqual(encoded.readUInt32BE(at: 0), 3)
        XCTAssertEqual(encoded[4], PeerMessage.portID)
        XCTAssertEqual(encoded.readUInt16BE(at: 5), 6881)

        let decoded = try PeerMessage.decode(from: Data(encoded.dropFirst(4)))
        XCTAssertEqual(decoded, portMsg)
    }

    func testDHTNodeEntryCreation() {
        let entry = DHTNodeEntry(id: .random(), address: "192.168.1.1", port: 6881)
        XCTAssertEqual(entry.address, "192.168.1.1")
        XCTAssertEqual(entry.port, 6881)
    }
}
