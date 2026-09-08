import Foundation
import NIOCore
import NIOPosix

/// Manages a single peer TCP connection using SwiftNIO.
public final class PeerConnection: @unchecked Sendable {
    public let address: String
    public let port: UInt16

    private var _channel: Channel?
    private let lock = NSLock()
    private let infoHash: Data
    private let peerID: Data

    public var onMessage: (@Sendable (PeerMessage) -> Void)?
    public var onDisconnect: (@Sendable () -> Void)?
    public private(set) var remotePeerID: Data?
    public private(set) var supportsExtensions: Bool = false

    public init(address: String, port: UInt16, infoHash: Data, peerID: Data) {
        self.address = address
        self.port = port
        self.infoHash = infoHash
        self.peerID = peerID
    }

    private func setChannel(_ ch: Channel) {
        lock.withLock {
            _channel = ch
        }
    }

    private func getChannel() -> Channel? {
        lock.withLock {
            _channel
        }
    }

    public func connect(on group: EventLoopGroup) async throws -> Channel {
        let onMsg = self.onMessage
        let onDisc = self.onDisconnect
        let decoder = PeerMessageDecoder(expectedInfoHash: infoHash)

        let bootstrap = ClientBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .connectTimeout(.seconds(4))
            .channelInitializer { channel in
                do {
                    let decoderHandler = ByteToMessageHandler(decoder)
                    let messageHandler = PeerMessageHandler(onMessage: onMsg, onDisconnect: onDisc)
                    try channel.pipeline.syncOperations.addHandler(decoderHandler)
                    try channel.pipeline.syncOperations.addHandler(messageHandler)
                    return channel.eventLoop.makeSucceededVoidFuture()
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }
        let ch = try await bootstrap.connect(host: address, port: Int(port)).get()

        setChannel(ch)

        // Send handshake as raw bytes (before the encoder is in the pipeline)
        let handshake = Handshake(infoHash: infoHash, peerID: peerID)
        var buffer = ch.allocator.buffer(capacity: Handshake.length)
        buffer.writeBytes(handshake.encode())
        try await ch.writeAndFlush(buffer).get()

        // Add the message encoder after handshake is sent
        try await ch.pipeline.addHandler(PeerMessageEncoder()).get()

        // Wait for remote handshake with timeout
        let remoteHandshake = try await decoder.waitForHandshake(timeout: .seconds(4))
        self.remotePeerID = remoteHandshake.peerID
        self.supportsExtensions = (remoteHandshake.reserved[5] & 0x10) != 0

        return ch
    }

    public func send(_ message: PeerMessage) async throws {
        guard let ch = getChannel() else {
            throw PeerConnectionError.notConnected
        }
        try await ch.writeAndFlush(message).get()
    }

    public func close() async throws {
        guard let ch = getChannel() else { return }
        try await ch.close().get()
    }
}

public enum PeerConnectionError: Error {
    case notConnected
    case handshakeFailed
    case handshakeTimeout
}

// MARK: - NIO Channel Handlers

/// Decodes peer wire protocol messages from byte stream.
final class PeerMessageDecoder: ByteToMessageDecoder, @unchecked Sendable {
    typealias InboundOut = PeerMessage

    private let expectedInfoHash: Data?
    private var handshakeReceived = false
    var remotePeerID: Data?
    var remoteSupportsExtensions: Bool = false

    private let lock = NSLock()
    private var handshakeContinuation: CheckedContinuation<Handshake, any Error>?

    init(expectedInfoHash: Data? = nil) {
        self.expectedInfoHash = expectedInfoHash
    }

    func waitForHandshake(timeout: TimeAmount) async throws -> Handshake {
        try await withCheckedThrowingContinuation { continuation in
            let existingHandshake: Handshake? = lock.withLock {
                if let remoteID = self.remotePeerID {
                    let reserved = Data(count: 8)
                    return Handshake(infoHash: self.expectedInfoHash ?? Data(count: 20), peerID: remoteID, reserved: reserved)
                }
                self.handshakeContinuation = continuation
                return nil
            }

            if let existing = existingHandshake {
                continuation.resume(returning: existing)
                return
            }

            let seconds = Double(timeout.nanoseconds) / 1_000_000_000.0
            Task {
                try? await Task.sleep(for: .seconds(max(seconds, 1)))
                let contToResume = self.lock.withLock { () -> (CheckedContinuation<Handshake, any Error>)? in
                    guard let cont = self.handshakeContinuation else { return nil }
                    self.handshakeContinuation = nil
                    return cont
                }
                contToResume?.resume(throwing: PeerConnectionError.handshakeTimeout)
            }
        }
    }

    func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        if !handshakeReceived {
            guard buffer.readableBytes >= Handshake.length else { return .needMoreData }
            guard let bytes = buffer.readBytes(length: Handshake.length) else { return .needMoreData }
            let handshake = try Handshake.decode(from: Data(bytes))

            if let expected = expectedInfoHash, handshake.infoHash != expected {
                throw PeerConnectionError.handshakeFailed
            }

            let cont = lock.withLock { () -> (CheckedContinuation<Handshake, any Error>)? in
                remotePeerID = handshake.peerID
                remoteSupportsExtensions = (handshake.reserved[5] & 0x10) != 0
                handshakeReceived = true
                let c = handshakeContinuation
                handshakeContinuation = nil
                return c
            }

            cont?.resume(returning: handshake)
            return .continue
        }

        guard buffer.readableBytes >= 4 else { return .needMoreData }
        let lengthBytes = buffer.getBytes(at: buffer.readerIndex, length: 4)!
        let length = Data(lengthBytes).readUInt32BE(at: 0)

        // Safety limit: max message length 16MB
        guard length <= 16 * 1024 * 1024 else {
            throw PeerMessageError.invalidPayload
        }

        if length == 0 {
            buffer.moveReaderIndex(forwardBy: 4)
            context.fireChannelRead(wrapInboundOut(.keepAlive))
            return .continue
        }

        guard buffer.readableBytes >= 4 + Int(length) else { return .needMoreData }
        buffer.moveReaderIndex(forwardBy: 4)
        guard let payload = buffer.readBytes(length: Int(length)) else { return .needMoreData }
        let message = try PeerMessage.decode(from: Data(payload))
        context.fireChannelRead(wrapInboundOut(message))
        return .continue
    }
}

/// Receives decoded PeerMessage and calls the callback.
final class PeerMessageHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = PeerMessage

    private let onMessage: (@Sendable (PeerMessage) -> Void)?
    private let onDisconnect: (@Sendable () -> Void)?

    init(onMessage: (@Sendable (PeerMessage) -> Void)?, onDisconnect: (@Sendable () -> Void)?) {
        self.onMessage = onMessage
        self.onDisconnect = onDisconnect
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        onMessage?(message)
    }

    func channelInactive(context: ChannelHandlerContext) {
        onDisconnect?()
    }
}

/// Encodes PeerMessage to bytes.
final class PeerMessageEncoder: ChannelOutboundHandler, @unchecked Sendable {
    typealias OutboundIn = PeerMessage
    typealias OutboundOut = ByteBuffer

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let message = unwrapOutboundIn(data)
        let encoded = message.encode()
        var buffer = context.channel.allocator.buffer(capacity: encoded.count)
        buffer.writeBytes(encoded)
        context.write(wrapOutboundOut(buffer), promise: promise)
    }
}
