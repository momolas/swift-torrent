import XCTest
@testable import SwiftTorrent

final class FastExtensionTests: XCTestCase {
    func testFastSetGenerationIsDeterministic() {
        let infoHash = Data(repeating: 0xAB, count: 20)
        let ip = "192.168.1.50"
        let set1 = FastExtension.generateFastSet(k: 7, pieceCount: 100, infoHash: infoHash, ip: ip)
        let set2 = FastExtension.generateFastSet(k: 7, pieceCount: 100, infoHash: infoHash, ip: ip)

        XCTAssertEqual(set1.count, 7)
        XCTAssertEqual(set1, set2)

        // All piece indices must be within 0..<100
        for index in set1 {
            XCTAssertTrue(index >= 0 && index < 100)
        }
        // All pieces in set must be unique
        XCTAssertEqual(Set(set1).count, set1.count)
    }

    func testFastSetSameSubnetSharesSet() {
        // BEP-6 specifies masking with 0xFFFFFF00: IPs in the same /24 subnet share the fast set
        let infoHash = Data(repeating: 0x42, count: 20)
        let set1 = FastExtension.generateFastSet(k: 10, pieceCount: 50, infoHash: infoHash, ip: "10.0.0.1")
        let set2 = FastExtension.generateFastSet(k: 10, pieceCount: 50, infoHash: infoHash, ip: "10.0.0.254")
        XCTAssertEqual(set1, set2)

        let setDifferentSubnet = FastExtension.generateFastSet(k: 10, pieceCount: 50, infoHash: infoHash, ip: "10.0.1.1")
        XCTAssertNotEqual(set1, setDifferentSubnet)
    }

    func testFastSetBounds() {
        let infoHash = Data(repeating: 0x01, count: 20)
        // If pieceCount is smaller than k, returns pieceCount pieces
        let setSmall = FastExtension.generateFastSet(k: 10, pieceCount: 3, infoHash: infoHash, ip: "1.2.3.4")
        XCTAssertEqual(setSmall.count, 3)
        XCTAssertEqual(Set(setSmall), Set([0, 1, 2]))

        // Empty cases
        XCTAssertTrue(FastExtension.generateFastSet(k: 0, pieceCount: 10, infoHash: infoHash, ip: "1.2.3.4").isEmpty)
        XCTAssertTrue(FastExtension.generateFastSet(k: 5, pieceCount: 0, infoHash: infoHash, ip: "1.2.3.4").isEmpty)
    }

    func testFastExtensionMessagesEncodingDecoding() throws {
        // Suggest Piece (ID 13)
        let suggest = PeerMessage.suggestPiece(pieceIndex: 42)
        let suggestData = suggest.encode()
        XCTAssertEqual(suggestData.readUInt32BE(at: 0), 5) // length prefix: 1 byte ID + 4 bytes payload
        XCTAssertEqual(suggestData[4], PeerMessage.suggestPieceID)
        let decodedSuggest = try PeerMessage.decode(from: Data(suggestData.dropFirst(4)))
        XCTAssertEqual(decodedSuggest, suggest)

        // Have All (ID 14)
        let haveAll = PeerMessage.haveAll
        let haveAllData = haveAll.encode()
        XCTAssertEqual(haveAllData.readUInt32BE(at: 0), 1)
        XCTAssertEqual(haveAllData[4], PeerMessage.haveAllID)
        let decodedHaveAll = try PeerMessage.decode(from: Data(haveAllData.dropFirst(4)))
        XCTAssertEqual(decodedHaveAll, haveAll)

        // Have None (ID 15)
        let haveNone = PeerMessage.haveNone
        let haveNoneData = haveNone.encode()
        XCTAssertEqual(haveNoneData.readUInt32BE(at: 0), 1)
        XCTAssertEqual(haveNoneData[4], PeerMessage.haveNoneID)
        let decodedHaveNone = try PeerMessage.decode(from: Data(haveNoneData.dropFirst(4)))
        XCTAssertEqual(decodedHaveNone, haveNone)

        // Reject Request (ID 16)
        let reject = PeerMessage.rejectRequest(index: 5, begin: 16384, length: 16384)
        let rejectData = reject.encode()
        XCTAssertEqual(rejectData.readUInt32BE(at: 0), 13)
        XCTAssertEqual(rejectData[4], PeerMessage.rejectRequestID)
        let decodedReject = try PeerMessage.decode(from: Data(rejectData.dropFirst(4)))
        XCTAssertEqual(decodedReject, reject)

        // Allowed Fast (ID 17)
        let allowedFast = PeerMessage.allowedFast(pieceIndex: 99)
        let allowedFastData = allowedFast.encode()
        XCTAssertEqual(allowedFastData.readUInt32BE(at: 0), 5)
        XCTAssertEqual(allowedFastData[4], PeerMessage.allowedFastID)
        let decodedAllowedFast = try PeerMessage.decode(from: Data(allowedFastData.dropFirst(4)))
        XCTAssertEqual(decodedAllowedFast, allowedFast)
    }

    func testHandshakeFastExtensionBit() {
        let reserved = Handshake.defaultReserved(enableFastExtension: true, enableDHT: false, isPrivate: false)
        let hs = Handshake(infoHash: Data(repeating: 1, count: 20), peerID: Data(repeating: 2, count: 20), reserved: reserved)
        XCTAssertTrue(hs.supportsFastExtension)
        XCTAssertFalse(hs.supportsDHT)

        let noFastReserved = Handshake.defaultReserved(enableFastExtension: false, enableDHT: false, isPrivate: false)
        let hsNoFast = Handshake(infoHash: Data(repeating: 1, count: 20), peerID: Data(repeating: 2, count: 20), reserved: noFastReserved)
        XCTAssertFalse(hsNoFast.supportsFastExtension)
    }

    func testPeerStateAllowedFastBypassChoke() async {
        let state = PeerState(pieceCount: 10)
        await state.setPeerChoking(true)
        await state.addAllowedFastPiece(3)

        let isChoking = await state.getPeerChoking()
        XCTAssertTrue(isChoking)
        let is3Allowed = await state.isAllowedFast(3)
        XCTAssertTrue(is3Allowed)
        let is4Allowed = await state.isAllowedFast(4)
        XCTAssertFalse(is4Allowed)

        // Adding pending request
        let reqAllowed = PeerState.BlockRequest(pieceIndex: 3, offset: 0, length: 16384)
        let reqBlocked = PeerState.BlockRequest(pieceIndex: 4, offset: 0, length: 16384)
        await state.addPendingRequest(reqAllowed)
        await state.addPendingRequest(reqBlocked)

        // Choke should drop requests EXCEPT allowed fast
        let dropped = await state.clearPendingRequestsExceptAllowedFast()
        XCTAssertEqual(dropped, [reqBlocked])
        let hasReqAllowed = await state.hasPending(reqAllowed)
        XCTAssertTrue(hasReqAllowed)
        let hasReqBlocked = await state.hasPending(reqBlocked)
        XCTAssertFalse(hasReqBlocked)
    }
}
