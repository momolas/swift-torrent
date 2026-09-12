import Foundation
import Network

/// UDP tracker client (BEP-15) using native Network.framework.
public final class UDPTracker: Sendable {
    public let host: String
    public let port: Int

    public init(host: String, port: Int, group: Any? = nil) {
        self.host = host
        self.port = port
    }

    /// Announce to the UDP tracker.
    public func announce(params: AnnounceParams) async throws -> AnnounceResponse {
        let connection = try await createReadyConnection(host: host, port: port)
        defer { connection.cancel() }

        // Step 1: Connect request
        let transactionID = UInt32.random(in: 0...UInt32.max)
        var connectReq = Data()
        connectReq.append(contentsOf: UInt64(0x41727101980).bigEndianBytes) // magic
        connectReq.append(contentsOf: UInt32(0).bigEndianBytes) // action: connect
        connectReq.append(contentsOf: transactionID.bigEndianBytes)

        let connectResponse = try await sendAndReceive(connection: connection, request: connectReq)
        guard connectResponse.count >= 16 else {
            throw TrackerError.invalidResponse
        }
        let respAction = connectResponse.readUInt32BE(at: 0)
        let respTxID = connectResponse.readUInt32BE(at: 4)
        guard respAction == 0, respTxID == transactionID else {
            throw TrackerError.invalidResponse
        }
        let connectionID = connectResponse.readUInt64BE(at: 8)

        // Step 2: Announce request
        let announceTxID = UInt32.random(in: 0...UInt32.max)
        var announceReq = Data()
        announceReq.append(contentsOf: connectionID.bigEndianBytes)
        announceReq.append(contentsOf: UInt32(1).bigEndianBytes) // action: announce
        announceReq.append(contentsOf: announceTxID.bigEndianBytes)
        announceReq.append(params.infoHash.bytes)
        announceReq.append(params.peerID)
        announceReq.append(contentsOf: params.downloaded.bigEndianBytes)
        announceReq.append(contentsOf: params.left.bigEndianBytes)
        announceReq.append(contentsOf: params.uploaded.bigEndianBytes)

        // Map event: 0=none, 1=completed, 2=started, 3=stopped
        let eventCode: UInt32
        switch params.event?.lowercased() {
        case "completed": eventCode = 1
        case "started": eventCode = 2
        case "stopped": eventCode = 3
        default: eventCode = 0
        }
        announceReq.append(contentsOf: eventCode.bigEndianBytes)
        announceReq.append(contentsOf: UInt32(0).bigEndianBytes) // IP
        announceReq.append(contentsOf: UInt32.random(in: 0...UInt32.max).bigEndianBytes) // key
        announceReq.append(contentsOf: Int32(params.numWant).bigEndianBytes)
        announceReq.append(contentsOf: params.port.bigEndianBytes)

        let announceResponse = try await sendAndReceive(connection: connection, request: announceReq)
        guard announceResponse.count >= 20 else {
            throw TrackerError.invalidResponse
        }
        let annAction = announceResponse.readUInt32BE(at: 0)
        let annTxID = announceResponse.readUInt32BE(at: 4)
        guard annAction == 1, annTxID == announceTxID else {
            throw TrackerError.invalidResponse
        }

        let interval = Int(announceResponse.readUInt32BE(at: 8))
        let leechers = Int(announceResponse.readUInt32BE(at: 12))
        let seeders = Int(announceResponse.readUInt32BE(at: 16))

        // Parse compact peers (6 bytes each: 4 IP + 2 port)
        var peers: [(String, UInt16)] = []
        var offset = 20
        while offset + 6 <= announceResponse.count {
            let start = announceResponse.startIndex + offset
            let ip = "\(announceResponse[start]).\(announceResponse[start + 1]).\(announceResponse[start + 2]).\(announceResponse[start + 3])"
            let peerPort = announceResponse.readUInt16BE(at: offset + 4)
            peers.append((ip, peerPort))
            offset += 6
        }

        return AnnounceResponse(interval: interval, seeders: seeders, leechers: leechers, peers: peers)
    }

    /// Scrape the UDP tracker (BEP-15).
    public func scrape(infoHashes: [InfoHash]) async throws -> [InfoHash: ScrapeInfo] {
        guard !infoHashes.isEmpty else { return [:] }

        let connection = try await createReadyConnection(host: host, port: port)
        defer { connection.cancel() }

        // Step 1: Connect request
        let transactionID = UInt32.random(in: 0...UInt32.max)
        var connectReq = Data()
        connectReq.append(contentsOf: UInt64(0x41727101980).bigEndianBytes) // magic
        connectReq.append(contentsOf: UInt32(0).bigEndianBytes) // action: connect
        connectReq.append(contentsOf: transactionID.bigEndianBytes)

        let connectResponse = try await sendAndReceive(connection: connection, request: connectReq)
        guard connectResponse.count >= 16 else {
            throw TrackerError.invalidResponse
        }
        let respAction = connectResponse.readUInt32BE(at: 0)
        let respTxID = connectResponse.readUInt32BE(at: 4)
        guard respAction == 0, respTxID == transactionID else {
            throw TrackerError.invalidResponse
        }
        let connectionID = connectResponse.readUInt64BE(at: 8)

        // Step 2: Scrape request (BEP 15)
        let scrapeTxID = UInt32.random(in: 0...UInt32.max)
        var scrapeReq = Data()
        scrapeReq.append(contentsOf: connectionID.bigEndianBytes)
        scrapeReq.append(contentsOf: UInt32(2).bigEndianBytes) // action: scrape (2)
        scrapeReq.append(contentsOf: scrapeTxID.bigEndianBytes)
        for hash in infoHashes {
            scrapeReq.append(hash.bytes)
        }

        let scrapeResponse = try await sendAndReceive(connection: connection, request: scrapeReq)
        guard scrapeResponse.count >= 8 + infoHashes.count * 12 else {
            throw TrackerError.invalidResponse
        }
        let scrapeAction = scrapeResponse.readUInt32BE(at: 0)
        let scrapeResTxID = scrapeResponse.readUInt32BE(at: 4)
        guard scrapeAction == 2, scrapeResTxID == scrapeTxID else {
            throw TrackerError.invalidResponse
        }

        var result: [InfoHash: ScrapeInfo] = [:]
        var offset = 8
        for hash in infoHashes {
            let seeders = Int(scrapeResponse.readUInt32BE(at: offset))
            let completed = Int(scrapeResponse.readUInt32BE(at: offset + 4))
            let leechers = Int(scrapeResponse.readUInt32BE(at: offset + 8))
            result[hash] = ScrapeInfo(seeders: seeders, leechers: leechers, completed: completed)
            offset += 12
        }

        return result
    }

    private func createReadyConnection(host: String, port: Int, timeoutSeconds: Double = 5.0) async throws -> NWConnection {
        let nwHost = NWEndpoint.Host(host)
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw TrackerError.invalidURL
        }
        let connection = NWConnection(host: nwHost, port: nwPort, using: .udp)
        let queue = DispatchQueue(label: "org.swifttorrent.udptracker.conn")

        return try await withCheckedThrowingContinuation { continuation in
            let resumed = AtomicFlag(false)

            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + timeoutSeconds)
            timer.setEventHandler {
                if resumed.testAndSet() {
                    timer.cancel()
                    connection.cancel()
                    continuation.resume(throwing: TrackerError.connectionFailed)
                }
            }
            timer.resume()

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if resumed.testAndSet() {
                        timer.cancel()
                        connection.stateUpdateHandler = nil
                        continuation.resume(returning: connection)
                    }
                case .failed(let error):
                    if resumed.testAndSet() {
                        timer.cancel()
                        connection.cancel()
                        continuation.resume(throwing: error)
                    }
                case .cancelled:
                    if resumed.testAndSet() {
                        timer.cancel()
                        continuation.resume(throwing: TrackerError.connectionFailed)
                    }
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    private func sendAndReceive(connection: NWConnection, request: Data, timeoutSeconds: Double = 5.0) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let resumed = AtomicFlag(false)

            let timer = DispatchSource.makeTimerSource(queue: .global())
            timer.schedule(deadline: .now() + timeoutSeconds)
            timer.setEventHandler {
                if resumed.testAndSet() {
                    timer.cancel()
                    continuation.resume(throwing: TrackerError.connectionFailed)
                }
            }
            timer.resume()

            connection.send(content: request, completion: .contentProcessed { error in
                if let error = error {
                    if resumed.testAndSet() {
                        timer.cancel()
                        continuation.resume(throwing: error)
                    }
                    return
                }
                connection.receiveMessage { content, context, isComplete, error in
                    if resumed.testAndSet() {
                        timer.cancel()
                        if let error = error {
                            continuation.resume(throwing: error)
                        } else if let data = content {
                            continuation.resume(returning: data)
                        } else {
                            continuation.resume(throwing: TrackerError.invalidResponse)
                        }
                    }
                }
            })
        }
    }
}

// MARK: - Big-endian helpers

extension UInt64 {
    var bigEndianBytes: [UInt8] {
        let be = self.bigEndian
        return withUnsafeBytes(of: be) { Array($0) }
    }
}

extension Int64 {
    var bigEndianBytes: [UInt8] {
        let be = self.bigEndian
        return withUnsafeBytes(of: be) { Array($0) }
    }
}

extension Int32 {
    var bigEndianBytes: [UInt8] {
        let be = self.bigEndian
        return withUnsafeBytes(of: be) { Array($0) }
    }
}

extension Data {
    func readUInt64BE(at offset: Int) -> UInt64 {
        let start = self.startIndex + offset
        var value: UInt64 = 0
        _ = Swift.withUnsafeMutableBytes(of: &value) { buf in
            self.copyBytes(to: buf, from: start..<start+8)
        }
        return UInt64(bigEndian: value)
    }
}

private final class AtomicFlag: @unchecked Sendable {
    private var value: Bool
    private let lock = NSLock()

    init(_ value: Bool) {
        self.value = value
    }

    func testAndSet() -> Bool {
        lock.withLock {
            if value { return false }
            value = true
            return true
        }
    }
}

