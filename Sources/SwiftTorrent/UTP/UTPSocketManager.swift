import Foundation
import NIOCore
import NIOPosix

/// Manages uTP connections multiplexed over a single UDP socket (BEP 29).
public actor UTPSocketManager {
    /// Active uTP connections keyed by (remoteAddress, connectionID).
    private var connections: [String: UTPConnection] = [:]
    private let group: EventLoopGroup
    private var channel: Channel?
    private let port: UInt16

    public init(port: UInt16, group: EventLoopGroup) {
        self.port = port
        self.group = group
    }

    /// Start listening for incoming uTP packets on the UDP port.
    public func start() async throws {
        let bootstrap = DatagramBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
        let ch = try await bootstrap.bind(host: "0.0.0.0", port: Int(port)).get()
        self.channel = ch
    }

    /// Initiate an outgoing uTP connection to a remote peer.
    public func connect(to address: String, port: UInt16) -> UTPConnection {
        let connID = UInt16.random(in: 1...UInt16.max)
        let key = "\(address):\(port):\(connID)"
        let conn = UTPConnection(
            remoteAddress: address,
            remotePort: port,
            connectionID: connID,
            isInitiator: true
        )
        connections[key] = conn
        return conn
    }

    /// Handle an incoming uTP packet.
    public func handlePacket(_ packet: UTPPacket, from address: String, port: UInt16) {
        let key = "\(address):\(port):\(packet.connectionID)"
        if let conn = connections[key] {
            conn.handlePacket(packet)
        } else if packet.type == .syn {
            // Accept incoming connection
            let conn = UTPConnection(
                remoteAddress: address,
                remotePort: port,
                connectionID: packet.connectionID,
                isInitiator: false
            )
            connections[key] = conn
            conn.handlePacket(packet)
        }
    }

    /// Remove a closed connection.
    public func removeConnection(key: String) {
        connections.removeValue(forKey: key)
    }
}

/// Represents a single uTP connection (state machine).
public final class UTPConnection: @unchecked Sendable {
    public enum State: Sendable {
        case idle
        case synSent
        case connected
        case finSent
        case closed
    }

    public let remoteAddress: String
    public let remotePort: UInt16
    public let connectionID: UInt16
    public let isInitiator: Bool

    private let lock = NSLock()
    private var _state: State = .idle
    private var _congestion = LEDBATCongestionControl()
    private var _sendSeqNr: UInt16 = 1
    private var _ackNr: UInt16 = 0
    private var _sendBuffer: [UTPPacket] = []
    private var _receiveBuffer: [UInt16: Data] = [:]

    public var state: State {
        lock.withLock { _state }
    }

    public init(
        remoteAddress: String,
        remotePort: UInt16,
        connectionID: UInt16,
        isInitiator: Bool
    ) {
        self.remoteAddress = remoteAddress
        self.remotePort = remotePort
        self.connectionID = connectionID
        self.isInitiator = isInitiator
    }

    /// Build a SYN packet to initiate a connection.
    public func buildSynPacket() -> UTPPacket {
        lock.withLock {
            _state = .synSent
            let ts = currentTimestampMicroseconds()
            let pkt = UTPPacket(
                type: .syn,
                connectionID: connectionID,
                timestampMicroseconds: ts,
                windowSize: UInt32(_congestion.cwnd),
                sequenceNumber: _sendSeqNr
            )
            _sendSeqNr &+= 1
            return pkt
        }
    }

    /// Build a DATA packet with the given payload.
    public func buildDataPacket(payload: Data) -> UTPPacket {
        lock.withLock {
            let ts = currentTimestampMicroseconds()
            let pkt = UTPPacket(
                type: .data,
                connectionID: connectionID,
                timestampMicroseconds: ts,
                windowSize: UInt32(_congestion.cwnd),
                sequenceNumber: _sendSeqNr,
                ackNumber: _ackNr,
                payload: payload
            )
            _sendSeqNr &+= 1
            _congestion.onSend(bytes: payload.count)
            return pkt
        }
    }

    /// Build a STATE (ACK) packet.
    public func buildStatePacket() -> UTPPacket {
        lock.withLock {
            let ts = currentTimestampMicroseconds()
            return UTPPacket(
                type: .state,
                connectionID: connectionID,
                timestampMicroseconds: ts,
                windowSize: UInt32(_congestion.cwnd),
                sequenceNumber: _sendSeqNr,
                ackNumber: _ackNr
            )
        }
    }

    /// Build a FIN packet.
    public func buildFinPacket() -> UTPPacket {
        lock.withLock {
            _state = .finSent
            let ts = currentTimestampMicroseconds()
            let pkt = UTPPacket(
                type: .fin,
                connectionID: connectionID,
                timestampMicroseconds: ts,
                windowSize: UInt32(_congestion.cwnd),
                sequenceNumber: _sendSeqNr,
                ackNumber: _ackNr
            )
            _sendSeqNr &+= 1
            return pkt
        }
    }

    /// Handle an incoming packet from the remote peer.
    public func handlePacket(_ packet: UTPPacket) {
        lock.withLock {
            switch packet.type {
            case .syn:
                if !isInitiator {
                    _ackNr = packet.sequenceNumber
                    _state = .connected
                }
            case .state:
                if _state == .synSent {
                    _state = .connected
                    _ackNr = packet.sequenceNumber &- 1
                }
                // Process ACK for congestion control
                let delay = Int64(packet.timestampDifference)
                let acked = Int(_congestion.mss) // simplified: 1 segment per ACK
                _congestion.onAck(sampleDelay: delay, bytesAcked: acked)

            case .data:
                _ackNr = packet.sequenceNumber
                _receiveBuffer[packet.sequenceNumber] = packet.payload

            case .fin:
                _ackNr = packet.sequenceNumber
                _state = .closed

            case .reset:
                _state = .closed
            }
        }
    }

    /// Check if the congestion window allows sending.
    public var canSend: Bool {
        lock.withLock { _congestion.canSend }
    }

    private func currentTimestampMicroseconds() -> UInt32 {
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        return UInt32((now / 1000) & 0xFFFFFFFF)
    }
}
