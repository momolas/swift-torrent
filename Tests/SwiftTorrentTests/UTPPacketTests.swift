import XCTest
@testable import SwiftTorrent

final class UTPPacketTests: XCTestCase {
    func testEncodeDecodeSYN() throws {
        let original = UTPPacket(
            type: .syn,
            connectionID: 0x1234,
            timestampMicroseconds: 1_000_000,
            timestampDifference: 0,
            windowSize: 65535,
            sequenceNumber: 1,
            ackNumber: 0
        )

        let encoded = original.encode()
        XCTAssertEqual(encoded.count, 20) // Header only

        let decoded = try UTPPacket.decode(from: encoded)
        XCTAssertEqual(decoded.type, .syn)
        XCTAssertEqual(decoded.version, 1)
        XCTAssertEqual(decoded.connectionID, 0x1234)
        XCTAssertEqual(decoded.timestampMicroseconds, 1_000_000)
        XCTAssertEqual(decoded.timestampDifference, 0)
        XCTAssertEqual(decoded.windowSize, 65535)
        XCTAssertEqual(decoded.sequenceNumber, 1)
        XCTAssertEqual(decoded.ackNumber, 0)
        XCTAssertTrue(decoded.payload.isEmpty)
    }

    func testEncodeDecodeDataWithPayload() throws {
        let payload = Data("uTP data chunk test payload with some length".utf8)
        let original = UTPPacket(
            type: .data,
            connectionID: 0xABCD,
            timestampMicroseconds: 5_500_200,
            timestampDifference: 12_400,
            windowSize: 131072,
            sequenceNumber: 42,
            ackNumber: 10,
            payload: payload
        )

        let encoded = original.encode()
        XCTAssertEqual(encoded.count, 20 + payload.count)

        let decoded = try UTPPacket.decode(from: encoded)
        XCTAssertEqual(decoded.type, .data)
        XCTAssertEqual(decoded.connectionID, 0xABCD)
        XCTAssertEqual(decoded.sequenceNumber, 42)
        XCTAssertEqual(decoded.ackNumber, 10)
        XCTAssertEqual(decoded.payload, payload)
    }

    func testEncodeDecodeWithSACKExtension() throws {
        let sackMask = Data([0xAA, 0x55, 0x0F, 0xF0])

        let original = UTPPacket(
            type: .state,
            connectionID: 0x5678,
            timestampMicroseconds: 9_999_999,
            timestampDifference: 25_000,
            windowSize: 1048576,
            sequenceNumber: 100,
            ackNumber: 99,
            sackBitmask: sackMask
        )

        let encoded = original.encode()
        let decoded = try UTPPacket.decode(from: encoded)

        XCTAssertEqual(decoded.type, .state)
        XCTAssertEqual(decoded.extensionType, UTPExtensionType.selectiveAck.rawValue)
        XCTAssertEqual(decoded.sackBitmask, sackMask)
    }

    func testDecodeTruncatedPacketThrows() {
        let truncated = Data(repeating: 0, count: 19) // Less than minimum 20 bytes
        XCTAssertThrowsError(try UTPPacket.decode(from: truncated)) { error in
            guard case UTPError.packetTooShort = error else {
                return XCTFail("Expected UTPError.packetTooShort, got \(error)")
            }
        }
    }

    func testUnknownPacketTypeThrows() {
        var raw = Data(repeating: 0, count: 20)
        raw[0] = 0x91 // Type 9, version 1
        XCTAssertThrowsError(try UTPPacket.decode(from: raw)) { error in
            guard case UTPError.unknownPacketType(9) = error else {
                return XCTFail("Expected UTPError.unknownPacketType(9), got \(error)")
            }
        }
    }
}
