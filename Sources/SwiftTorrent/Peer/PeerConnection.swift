import Foundation
import Network

/// Manages a single peer TCP connection using native Network.framework.
public final class PeerConnection: @unchecked Sendable {
    public let address: String
    public let port: UInt16

    private var connection: NWConnection?
    private var receiveTask: Task<Void, Never>?
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "org.swifttorrent.peerconnection", qos: .userInitiated)

    private let infoHash: Data
    private let peerID: Data

    public var onMessage: (@Sendable (PeerMessage) -> Void)?
    public var onDisconnect: (@Sendable () -> Void)?
    public private(set) var remotePeerID: Data?
    public private(set) var supportsExtensions: Bool = false
    public private(set) var supportsFastExtension: Bool = false
    public private(set) var supportsDHT: Bool = false

    public let isPrivate: Bool
    public let enableFastExtension: Bool
    public let enableDHT: Bool

    public init(
        address: String,
        port: UInt16,
        infoHash: Data,
        peerID: Data,
        isPrivate: Bool = false,
        enableFastExtension: Bool = true,
        enableDHT: Bool = true
    ) {
        self.address = address
        self.port = port
        self.infoHash = infoHash
        self.peerID = peerID
        self.isPrivate = isPrivate
        self.enableFastExtension = enableFastExtension
        self.enableDHT = enableDHT
    }

    public func connect(on group: Any? = nil) async throws {
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(address),
            port: NWEndpoint.Port(rawValue: port) ?? 6881
        )
        let tcpParams = NWParameters.tcp
        let conn = NWConnection(to: endpoint, using: tcpParams)

        lock.withLock {
            self.connection = conn
        }

        // Wait for connection to be ready with 4-second timeout
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await Task.sleep(for: .seconds(4))
                throw PeerConnectionError.handshakeTimeout
            }

            group.addTask {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    let resumed = AtomicFlag(false)
                    conn.stateUpdateHandler = { state in
                        switch state {
                        case .ready:
                            if resumed.testAndSet() {
                                cont.resume()
                            }
                        case .failed(let err):
                            if resumed.testAndSet() {
                                cont.resume(throwing: err)
                            }
                        case .cancelled:
                            if resumed.testAndSet() {
                                cont.resume(throwing: PeerConnectionError.notConnected)
                            }
                        default:
                            break
                        }
                    }
                    conn.start(queue: self.queue)
                }
            }

            try await group.next()
            group.cancelAll()
        }

        // Perform handshake with 4-second timeout
        var receiveBuffer = Data()
        let handshakeResp: Handshake = try await withThrowingTaskGroup(of: Handshake.self) { group in
            group.addTask {
                try await Task.sleep(for: .seconds(4))
                throw PeerConnectionError.handshakeTimeout
            }

            group.addTask {
                let reserved = Handshake.defaultReserved(
                    enableFastExtension: self.enableFastExtension,
                    enableDHT: self.enableDHT,
                    isPrivate: self.isPrivate
                )
                let handshake = Handshake(infoHash: self.infoHash, peerID: self.peerID, reserved: reserved)
                let handshakeData = handshake.encode()
                try await self.sendRaw(connection: conn, data: handshakeData)

                let rawData = try await self.receiveExact(connection: conn, count: Handshake.length, buffer: &receiveBuffer)
                guard let decoded = try? Handshake.decode(from: rawData) else {
                    throw PeerConnectionError.handshakeFailed
                }
                if decoded.infoHash != self.infoHash {
                    throw PeerConnectionError.handshakeFailed
                }
                return decoded
            }

            let first = try await group.next()!
            group.cancelAll()
            return first
        }

        self.remotePeerID = handshakeResp.peerID
        self.supportsExtensions = handshakeResp.supportsExtensions
        self.supportsFastExtension = self.enableFastExtension && handshakeResp.supportsFastExtension
        self.supportsDHT = self.enableDHT && !self.isPrivate && handshakeResp.supportsDHT

        // Start message receive loop
        let task = Task { [weak self] in
            guard let self else { return }
            await self.messageReceiveLoop(connection: conn, initialBuffer: receiveBuffer)
        }
        lock.withLock {
            self.receiveTask = task
        }
    }

    public func send(_ message: PeerMessage) async throws {
        guard let conn = lock.withLock({ connection }) else {
            throw PeerConnectionError.notConnected
        }
        let data = message.encode()
        try await sendRaw(connection: conn, data: data)
    }

    public func close() async throws {
        let (conn, task) = lock.withLock { () -> (NWConnection?, Task<Void, Never>?) in
            let c = connection
            let t = receiveTask
            connection = nil
            receiveTask = nil
            return (c, t)
        }
        task?.cancel()
        conn?.cancel()
    }

    // MARK: - Private Helpers

    private func sendRaw(connection: NWConnection, data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume()
                }
            })
        }
    }

    private func receiveExact(connection: NWConnection, count: Int, buffer: inout Data) async throws -> Data {
        while buffer.count < count {
            let needed = count - buffer.count
            let chunk = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                connection.receive(minimumIncompleteLength: 1, maximumLength: max(needed, 16384)) { data, _, isComplete, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let data, !data.isEmpty {
                        continuation.resume(returning: data)
                    } else if isComplete {
                        continuation.resume(throwing: PeerConnectionError.notConnected)
                    } else {
                        continuation.resume(throwing: PeerConnectionError.notConnected)
                    }
                }
            }
            buffer.append(chunk)
        }
        let result = buffer.prefix(count)
        buffer.removeFirst(count)
        return Data(result)
    }

    private func messageReceiveLoop(connection: NWConnection, initialBuffer: Data) async {
        var buffer = initialBuffer
        while !Task.isCancelled {
            do {
                let lengthData = try await receiveExact(connection: connection, count: 4, buffer: &buffer)
                let length = lengthData.readUInt32BE(at: 0)

                if length == 0 {
                    onMessage?(.keepAlive)
                    continue
                }

                // Safety limit: max message length 16MB
                guard length <= 16 * 1024 * 1024 else {
                    break
                }

                let payload = try await receiveExact(connection: connection, count: Int(length), buffer: &buffer)
                let message = try PeerMessage.decode(from: payload)
                onMessage?(message)
            } catch {
                break
            }
        }

        connection.cancel()
        onDisconnect?()
    }
}

public enum PeerConnectionError: Error {
    case notConnected
    case handshakeFailed
    case handshakeTimeout
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
