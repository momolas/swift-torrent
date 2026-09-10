import XCTest
@testable import SwiftTorrent

final class LEDBATTests: XCTestCase {
    func testInitialState() {
        let cc = LEDBATCongestionControl(mss: 1400)
        XCTAssertEqual(LEDBATCongestionControl.targetDelay, 100_000)
        XCTAssertEqual(cc.cwnd, 2800) // 2 * mss
        XCTAssertTrue(cc.canSend)
    }

    func testWindowGrowthOnLowDelay() {
        var cc = LEDBATCongestionControl(mss: 1400)

        // Establish a base delay of 20ms = 20,000us
        cc.onAck(sampleDelay: 20_000, bytesAcked: 1400)
        let initialWindow = cc.cwnd

        // Feed ACKs with low delay (25ms -> queuing_delay = 5ms << target 100ms)
        // off_target is strongly positive -> window should increase
        for _ in 1...10 {
            cc.onAck(sampleDelay: 25_000, bytesAcked: 1400)
        }

        XCTAssertGreaterThan(cc.cwnd, initialWindow)
    }

    func testWindowReductionOnHighDelay() {
        var cc = LEDBATCongestionControl(mss: 1400)

        // Grow window first with low delay
        for _ in 1...20 {
            cc.onAck(sampleDelay: 20_000, bytesAcked: 1400)
        }
        let peakWindow = cc.cwnd

        // Simulate queue buildup: delay jumps to 150ms (queuing delay = 130ms > target 100ms)
        for _ in 1...10 {
            cc.onAck(sampleDelay: 150_000, bytesAcked: 1400)
        }

        XCTAssertLessThan(cc.cwnd, peakWindow)
    }

    func testTimeoutResetsWindow() {
        var cc = LEDBATCongestionControl(mss: 1400)

        // Grow window
        for _ in 1...20 {
            cc.onAck(sampleDelay: 10_000, bytesAcked: 1400)
        }
        XCTAssertGreaterThan(cc.cwnd, 2800)

        // On timeout, must collapse back to minCWND
        cc.onTimeout()
        XCTAssertEqual(cc.cwnd, LEDBATCongestionControl.minCWND)
    }

    func testCanSendReflectsBytesInFlight() {
        var cc = LEDBATCongestionControl(mss: 1400)
        XCTAssertTrue(cc.canSend)

        cc.onSend(bytes: 2800) // fills the 2800 cwnd
        XCTAssertFalse(cc.canSend)

        cc.onAck(sampleDelay: 20_000, bytesAcked: 1400)
        XCTAssertTrue(cc.canSend)
    }
}
