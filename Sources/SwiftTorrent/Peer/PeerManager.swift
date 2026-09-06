import Foundation
import NIOCore
import NIOPosix

/// Manages the pool of peer connections for a torrent.
public actor PeerManager {
    private let infoHash: Data
    private let peerID: Data
    private let group: EventLoopGroup
    private var connections: [String: PeerConnection] = [:]
    private var connectedPeers: Set<String> = []
    private var peerInfos: [String: PeerInfo] = [:]
    private var peerStates: [String: PeerState] = [:]
    private let maxConnections: Int

    public var pieceManager: PieceManager?
    public var piecePicker: PiecePicker?
    public var diskIO: DiskIO?
    public var metadataExchange: MetadataExchange?
    public var onPieceCompleted: ((Int) -> Void)?
    public var onBlockReceived: ((Int) -> Void)?
    public var onMetadataReceived: ((TorrentInfo) -> Void)?
    private var globalPendingRequests: [PeerState.BlockRequest: String] = [:]

    private var pieceCount: Int = 0

    public init(infoHash: Data, peerID: Data, group: EventLoopGroup, maxConnections: Int = 50) {
        self.infoHash = infoHash
        self.peerID = peerID
        self.group = group
        self.maxConnections = maxConnections
    }

    public func configure(pieceManager: PieceManager, piecePicker: PiecePicker, diskIO: DiskIO, pieceCount: Int) {
        self.pieceManager = pieceManager
        self.piecePicker = piecePicker
        self.diskIO = diskIO
        self.pieceCount = pieceCount
    }

    public func configureMagnet(metadataExchange: MetadataExchange) {
        self.metadataExchange = metadataExchange
    }

    public func setOnMetadataReceived(_ handler: @escaping (TorrentInfo) -> Void) {
        self.onMetadataReceived = handler
    }

    public func setOnPieceCompleted(_ handler: @escaping (Int) -> Void) {
        self.onPieceCompleted = handler
    }

    public func setOnBlockReceived(_ handler: @escaping (Int) -> Void) {
        self.onBlockReceived = handler
    }

    /// Add a peer and attempt connection.
    public func addPeer(address: String, port: UInt16) async {
        let key = "\(address):\(port)"
        guard connections[key] == nil else { return }
        guard connections.count < maxConnections else { return }

        let conn = PeerConnection(address: address, port: port, infoHash: infoHash, peerID: peerID)
        connections[key] = conn
        peerInfos[key] = PeerInfo(id: Data(), address: address, port: port)

        // Set up message callbacks
        conn.onMessage = { [weak self] message in
            guard let self else { return }
            Task { await self.handleMessage(message, from: key) }
        }
        conn.onDisconnect = { [weak self] in
            guard let self else { return }
            Task { await self.handleDisconnect(key: key) }
        }

        Task {
            do {
                let _ = try await conn.connect(on: group)
                await self.onPeerConnected(key: key, conn: conn)
            } catch {
                await self.removePeerByKey(key)
            }
        }
    }

    private func onPeerConnected(key: String, conn: PeerConnection) async {
        connectedPeers.insert(key)

        let pc = pieceCount > 0 ? pieceCount : 1
        let state = PeerState(pieceCount: pc)
        await state.setAmInterested(true)
        peerStates[key] = state

        // Send interested
        try? await conn.send(.interested)

        // If peer supports extensions and we need metadata, send extended handshake
        if conn.supportsExtensions, let metaEx = metadataExchange {
            let extHandshake = await metaEx.buildExtendedHandshake()
            try? await conn.send(.extended(id: 0, payload: extHandshake))
        }
    }

    private func handleDisconnect(key: String) {
        if let state = peerStates[key] {
            Task {
                let bf = await state.getPeerBitfield()
                if var picker = self.piecePicker {
                    picker.removePeerBitfield(bf)
                    self.piecePicker = picker
                }
            }
        }
        connections.removeValue(forKey: key)
        peerInfos.removeValue(forKey: key)
        peerStates.removeValue(forKey: key)
        connectedPeers.remove(key)
    }

    private func handleMessage(_ message: PeerMessage, from key: String) async {
        guard let state = peerStates[key] else { return }

        switch message {
        case .bitfield(let data):
            let bf = Bitfield(data: data, count: pieceCount > 0 ? pieceCount : data.count * 8)
            await state.setPeerBitfield(bf)
            if var picker = piecePicker {
                picker.addPeerBitfield(bf)
                piecePicker = picker
            }
            peerInfos[key]?.peerBitfield = bf
            await fillRequests(for: key)

        case .have(let pieceIndex):
            let idx = Int(pieceIndex)
            await state.setHave(idx)
            if var picker = piecePicker {
                picker.addHave(idx)
                piecePicker = picker
            }
            await fillRequests(for: key)

        case .choke:
            await state.setPeerChoking(true)
            await state.clearPendingRequests()

        case .unchoke:
            await state.setPeerChoking(false)
            await fillRequests(for: key)

        case .interested:
            await state.setPeerInterested(true)

        case .notInterested:
            await state.setPeerInterested(false)

        case .piece(let index, let begin, let block):
            let pieceIndex = Int(index)
            let offset = Int(begin)
            let request = PeerState.BlockRequest(pieceIndex: pieceIndex, offset: offset, length: block.count)
            await state.removePendingRequest(request)
            globalPendingRequests.removeValue(forKey: request)
            onBlockReceived?(block.count)

            guard let pm = pieceManager else { break }
            await pm.addBlock(pieceIndex: pieceIndex, offset: offset, data: block)

            // Only complete piece when ALL blocks for this piece are received
            if await pm.areAllBlocksReceived(pieceIndex) {
                if let buf = await pm.getPieceBuffer(pieceIndex) {
                    await onPieceComplete(index: pieceIndex, data: buf)
                }
            }

            await fillRequests(for: key)

        case .extended(let extID, let payload):
            if let metaEx = metadataExchange {
                let result = await metaEx.handleExtendedMessage(id: extID, payload: payload)
                switch result {
                case .sendMessage(let msg):
                    try? await connections[key]?.send(msg)
                case .requestMore(let messages):
                    for msg in messages {
                        try? await connections[key]?.send(msg)
                    }
                case .metadataComplete(let info):
                    onMetadataReceived?(info)
                case .none:
                    break
                }
            }

        default:
            break
        }
    }

    private func fillRequests(for key: String) async {
        guard let state = peerStates[key],
              let pm = pieceManager,
              let conn = connections[key] else { return }

        let peerChoking = await state.getPeerChoking()
        guard !peerChoking else { return }

        let completed = await pm.getCompleted()
        let inProgress = await pm.getInProgress()
        let peerBF = await state.getPeerBitfield()

        var triedPieces: Set<Int> = []

        while await state.canRequest {
            var targetPiece: Int? = nil

            // 1. Try unfinished pieces in progress first that this peer has
            for inProgIdx in inProgress {
                if !completed.get(inProgIdx) && peerBF.get(inProgIdx) && !triedPieces.contains(inProgIdx) {
                    if !(await isPieceFullyRequested(inProgIdx, pieceManager: pm)) {
                        targetPiece = inProgIdx
                        break
                    } else {
                        triedPieces.insert(inProgIdx)
                    }
                }
            }

            // 2. Otherwise pick a new piece with rarest-first
            if targetPiece == nil, let picker = piecePicker {
                var tempHave = completed
                for tried in triedPieces {
                    tempHave.set(tried)
                }
                for inProg in inProgress {
                    tempHave.set(inProg)
                }
                if let picked = picker.pick(have: tempHave, peerHas: peerBF) {
                    targetPiece = picked
                }
            }

            guard let pieceIndex = targetPiece else { break }
            triedPieces.insert(pieceIndex)

            if await pm.hasPiece(pieceIndex) { continue }

            if !(await pm.isInProgress(pieceIndex)) {
                await pm.startPiece(pieceIndex)
            }

            let pieceSize = await pm.expectedPieceSize(pieceIndex)
            let blockSize = 16384
            var offset = 0

            while offset < pieceSize {
                let canReq = await state.canRequest
                guard canReq else { break }

                let alreadyReceived = await pm.isBlockReceived(pieceIndex: pieceIndex, offset: offset)
                let length = min(blockSize, pieceSize - offset)
                let request = PeerState.BlockRequest(pieceIndex: pieceIndex, offset: offset, length: length)
                let alreadyPendingGlobally = (globalPendingRequests[request] != nil)

                if !alreadyReceived && !alreadyPendingGlobally {
                    globalPendingRequests[request] = key
                    await state.addPendingRequest(request)
                    try? await conn.send(.request(
                        index: UInt32(pieceIndex),
                        begin: UInt32(offset),
                        length: UInt32(length)
                    ))
                }
                offset += blockSize
            }
        }
    }

    private func isPieceFullyRequested(_ pieceIndex: Int, pieceManager: PieceManager) async -> Bool {
        let pieceSize = await pieceManager.expectedPieceSize(pieceIndex)
        let blockSize = 16384
        var offset = 0
        while offset < pieceSize {
            let length = min(blockSize, pieceSize - offset)
            let request = PeerState.BlockRequest(pieceIndex: pieceIndex, offset: offset, length: length)
            let received = await pieceManager.isBlockReceived(pieceIndex: pieceIndex, offset: offset)
            let pending = (globalPendingRequests[request] != nil)
            if !received && !pending {
                return false
            }
            offset += blockSize
        }
        return true
    }

    private func onPieceComplete(index pieceIndex: Int, data: Data) async {
        guard let pm = pieceManager else { return }
        let verified = await pm.completePiece(pieceIndex)
        if verified {
            // Write to disk
            if let dio = diskIO {
                try? await dio.writePiece(index: pieceIndex, data: data)
            }
            await broadcastHave(pieceIndex: UInt32(pieceIndex))
            onPieceCompleted?(pieceIndex)
        }
    }

    private func removePeerByKey(_ key: String) {
        connections.removeValue(forKey: key)
        peerInfos.removeValue(forKey: key)
        peerStates.removeValue(forKey: key)
        connectedPeers.remove(key)
        globalPendingRequests = globalPendingRequests.filter { $0.value != key }
    }

    /// Remove a peer.
    public func removePeer(address: String, port: UInt16) async {
        let key = "\(address):\(port)"
        if let conn = connections.removeValue(forKey: key) {
            try? await conn.close()
        }
        peerInfos.removeValue(forKey: key)
        peerStates.removeValue(forKey: key)
        connectedPeers.remove(key)
    }

    /// Get all connected peer infos.
    public func peers() -> [PeerInfo] {
        Array(peerInfos.values)
    }

    /// Number of active connections.
    /// Returns snapshot of all currently known peers.
    public func getPeers() -> [PeerInfo] {
        Array(peerInfos.values)
    }

    public var connectionCount: Int {
        connections.count
    }

    /// Number of peers that completed the TCP handshake.
    public var connectedCount: Int {
        connectedPeers.count
    }

    /// Send interested message to all peers.
    public func sendInterestedToAll() async {
        let msg = PeerMessage.interested
        for (key, conn) in connections {
            guard connectedPeers.contains(key) else { continue }
            try? await conn.send(msg)
        }
    }

    /// Broadcast a have message to all peers.
    public func broadcastHave(pieceIndex: UInt32) async {
        let msg = PeerMessage.have(pieceIndex: pieceIndex)
        for (key, conn) in connections {
            guard connectedPeers.contains(key) else { continue }
            try? await conn.send(msg)
        }
    }

    /// Check for timed-out requests and cancel them.
    public func checkTimeouts() async {
        for (key, state) in peerStates {
            let timedOut = await state.timedOutRequests()
            for request in timedOut {
                await state.removePendingRequest(request)
                globalPendingRequests.removeValue(forKey: request)
            }
            if !timedOut.isEmpty {
                await fillRequests(for: key)
            }
        }
    }

    /// Disconnect all active peers and release resources.
    public func disconnectAll() async {
        for conn in connections.values {
            try? await conn.close()
        }
        connections.removeAll()
        peerInfos.removeAll()
        peerStates.removeAll()
        connectedPeers.removeAll()
        globalPendingRequests.removeAll()
    }
}
