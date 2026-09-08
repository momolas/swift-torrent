import XCTest
@testable import SwiftTorrent

final class SequentialStreamEngineTests: XCTestCase {
    func testHeaderAndFooterPriority() {
        let engine = SequentialStreamEngine(totalPieces: 100, currentPlaybackPiece: 0, bufferWindowPieces: 10)

        // Piece 0 (header) should have highest priority (lowest score)
        XCTAssertEqual(engine.priority(for: 0), 0)
        XCTAssertEqual(engine.priority(for: 1), 1)

        // Footer pieces (last 2% -> piece 98, 99) should have second priority
        XCTAssertTrue(engine.priority(for: 98) < 200)
        XCTAssertTrue(engine.priority(for: 99) < 200)

        // Immediate playback window (e.g. piece 5)
        XCTAssertTrue(engine.priority(for: 5) < 300)

        // Remote future piece (e.g. piece 50)
        XCTAssertTrue(engine.priority(for: 50) >= 1000)
    }

    func testSortedCandidates() {
        let engine = SequentialStreamEngine(totalPieces: 100, currentPlaybackPiece: 10, bufferWindowPieces: 5)
        let candidates = [50, 99, 0, 11, 80]
        let sorted = engine.sortedCandidates(candidates)

        // 0 (header) comes first, then 99 (footer), then 11 (playback window), then 50, then 80
        XCTAssertEqual(sorted.first, 0)
        XCTAssertEqual(sorted[1], 99)
        XCTAssertEqual(sorted[2], 11)
    }
}
