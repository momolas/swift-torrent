import Foundation

/// Manages the pool of peer connections for a torrent.
public actor PeerManager {
    private let infoHash: Data
    private let peerID: Data
    private var connections: [String: PeerConnection] = [:]
    private var connectedPeers: Set<String> = []
    private var peerInfos: [String: PeerInfo] = [:]
    private var peerStates: [String: PeerState] = [:]
    private var candidatePeers: [(address: String, port: UInt16)] = []
    private var connectingKeys: Set<String> = []
    private let maxConnections: Int

    public var pieceManager: PieceManager?
    public var piecePicker: PiecePicker?
    public var diskIO: DiskIO?
    public var metadataExchange: MetadataExchange?
    public var onPieceCompleted: ((Int) -> Void)?
    public var onBlockReceived: ((Int) -> Void)?
    public var onBlockSent: ((Int) -> Void)?
    public var onMetadataReceived: ((TorrentInfo) -> Void)?
    public var onDHTPortReceived: ((String, UInt16) -> Void)?
    private var globalPendingRequests: [PeerState.BlockRequest: String] = [:]

    public let isPrivate: Bool
    public var dhtPort: UInt16?
    private var remotePexIDs: [String: UInt8] = [:]
    private var pexAddedSinceLast: Set<PeerExchange.PeerEntry> = []
    private var pexDroppedSinceLast: Set<PeerExchange.PeerEntry> = []
    private var pexBroadcastTask: Task<Void, Never>?
    private let localPexID: UInt8 = PeerExchange.defaultLocalExtensionID

    private var pieceCount: Int = 0

    public init(
        infoHash: Data,
        peerID: Data,
        group: Any? = nil,
        maxConnections: Int = 50,
        isPrivate: Bool = false,
        dhtPort: UInt16? = nil
    ) {
        self.infoHash = infoHash
        self.peerID = peerID
        self.maxConnections = maxConnections
        self.isPrivate = isPrivate
        self.dhtPort = dhtPort
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

    public func setOnBlockSent(_ handler: @escaping (Int) -> Void) {
        self.onBlockSent = handler
    }

    public func setOnDHTPortReceived(_ handler: @escaping (String, UInt16) -> Void) {
        self.onDHTPortReceived = handler
    }

    /// Enqueue multiple peer candidates and start connecting up to maxConnections.
    public func addPeers(_ newPeers: [(String, UInt16)]) async {
        for (addr, port) in newPeers {
            let key = "\(addr):\(port)"
            if connections[key] == nil && !candidatePeers.contains(where: { $0.address == addr && $0.port == port }) {
                candidatePeers.append((address: addr, port: port))
            }
        }
        await replenishConnections()
    }

    /// Replenish connection pool up to maxConnections from queued candidates.
    public func replenishConnections() async {
        while connections.count < maxConnections && !candidatePeers.isEmpty {
            let candidate = candidatePeers.removeFirst()
            await addPeer(address: candidate.address, port: candidate.port)
        }
    }

    /// Add a peer and attempt connection.
    public func addPeer(address: String, port: UInt16) async {
        let key = "\(address):\(port)"
        guard connections[key] == nil else { return }
        guard connections.count < maxConnections else {
            if !candidatePeers.contains(where: { $0.address == address && $0.port == port }) {
                candidatePeers.append((address: address, port: port))
            }
            return
        }

        let pc = pieceCount > 0 ? pieceCount : 1
        let state = PeerState(pieceCount: pc)
        peerStates[key] = state

        let conn = PeerConnection(
            address: address,
            port: port,
            infoHash: infoHash,
            peerID: peerID,
            isPrivate: isPrivate,
            enableFastExtension: true,
            enableDHT: !isPrivate
        )
        connections[key] = conn
        peerInfos[key] = PeerInfo(id: Data(), address: address, port: port)
        connectingKeys.insert(key)

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
                try await conn.connect()
                await self.onPeerConnected(key: key, conn: conn)
            } catch {
                self.removePeerByKey(key)
                await self.replenishConnections()
            }
        }
    }

    private func onPeerConnected(key: String, conn: PeerConnection) async {
        connectingKeys.remove(key)
        connectedPeers.insert(key)

        guard let state = peerStates[key] else { return }
        await state.setCapabilities(
            extensions: conn.supportsExtensions,
            fastExtension: conn.supportsFastExtension,
            dht: conn.supportsDHT
        )
        await state.setAmInterested(true)

        // 1. BEP-6 Fast Extension or BEP-3 Bitfield
        if conn.supportsFastExtension {
            if let pm = pieceManager {
                let isComplete = await pm.isComplete()
                let completedBf = await pm.getCompleted()
                if isComplete {
                    try? await conn.send(.haveAll)
                } else if completedBf.isEmpty {
                    try? await conn.send(.haveNone)
                } else {
                    try? await conn.send(.bitfield(completedBf.toData()))
                }
            }
            if pieceCount > 0 {
                let fastSet = FastExtension.generateFastSet(
                    k: min(10, pieceCount),
                    pieceCount: pieceCount,
                    infoHash: infoHash,
                    ip: conn.address
                )
                for pieceIdx in fastSet {
                    try? await conn.send(.allowedFast(pieceIndex: UInt32(pieceIdx)))
                    await state.addMyAllowedFastPieceSent(pieceIdx)
                }
            }
        } else {
            if let pm = pieceManager {
                let completedBf = await pm.getCompleted()
                if !completedBf.isEmpty {
                    try? await conn.send(.bitfield(completedBf.toData()))
                }
            }
        }

        // 2. BEP-5 DHT Port message
        if conn.supportsDHT && !isPrivate, let port = dhtPort {
            try? await conn.send(.port(port))
        }

        // 3. Send interested
        try? await conn.send(.interested)

        // 4. BEP-10 Extended Handshake (ut_metadata and ut_pex)
        if conn.supportsExtensions {
            var mDict: [(key: Data, value: BencodeValue)] = []
            if metadataExchange != nil {
                mDict.append((key: Data("ut_metadata".utf8), value: .integer(1)))
            }
            if !isPrivate {
                mDict.append((key: Data(PeerExchange.extensionName.utf8), value: .integer(Int64(localPexID))))
            }
            if !mDict.isEmpty {
                let msg = BencodeValue.dictionary([
                    (key: Data("m".utf8), value: .dictionary(mDict))
                ])
                let payload = BencodeEncoder().encode(msg)
                try? await conn.send(.extended(id: 0, payload: payload))
            }
        }

        // 5. BEP-11 PEX tracking
        if !isPrivate {
            let isSeed = await pieceManager?.isComplete() ?? false
            pexAddedSinceLast.insert(PeerExchange.PeerEntry(address: conn.address, port: conn.port, isSeed: isSeed))
            startPEXLoop()
        }

        // 6. Fill piece requests immediately
        await fillRequests(for: key)
    }

    private func handleDisconnect(key: String) async {
        remotePexIDs.removeValue(forKey: key)
        if !isPrivate, let info = peerInfos[key] {
            pexDroppedSinceLast.insert(PeerExchange.PeerEntry(address: info.address, port: info.port))
        }
        if let state = peerStates[key] {
            let bf = await state.getPeerBitfield()
            if var picker = self.piecePicker {
                picker.removePeerBitfield(bf)
                self.piecePicker = picker
            }
        }
        removePeerByKey(key)
        await replenishConnections()
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

        case .port(let dhtPort):
            if !isPrivate, let info = peerInfos[key] {
                onDHTPortReceived?(info.address, dhtPort)
            }

        case .choke:
            await state.setPeerChoking(true)
            if connections[key]?.supportsFastExtension == true {
                let dropped = await state.clearPendingRequestsExceptAllowedFast()
                for req in dropped {
                    globalPendingRequests.removeValue(forKey: req)
                }
            } else {
                await state.clearPendingRequests()
            }

        case .unchoke:
            await state.setPeerChoking(false)
            await fillRequests(for: key)

        case .interested:
            await state.setPeerInterested(true)
            await state.setAmChoking(false)
            try? await connections[key]?.send(.unchoke)

        case .notInterested:
            await state.setPeerInterested(false)

        case .haveAll:
            let count = pieceCount > 0 ? pieceCount : 1
            let bf = Bitfield(count: count, allSet: true)
            await state.setPeerBitfield(bf)
            if var picker = piecePicker {
                picker.addPeerBitfield(bf)
                piecePicker = picker
            }
            peerInfos[key]?.peerBitfield = bf
            await fillRequests(for: key)

        case .haveNone:
            let count = pieceCount > 0 ? pieceCount : 1
            let bf = Bitfield(count: count, allSet: false)
            await state.setPeerBitfield(bf)
            peerInfos[key]?.peerBitfield = bf

        case .suggestPiece(let pieceIndex):
            await state.addSuggestedPiece(Int(pieceIndex))

        case .allowedFast(let pieceIndex):
            await state.addAllowedFastPiece(Int(pieceIndex))
            await fillRequests(for: key)

        case .rejectRequest(let index, let begin, let length):
            let req = PeerState.BlockRequest(pieceIndex: Int(index), offset: Int(begin), length: Int(length))
            await state.removePendingRequest(req)
            globalPendingRequests.removeValue(forKey: req)
            await fillRequests(for: key)

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
            if extID == 0 {
                // Extended handshake (BEP-10)
                let decoder = BencodeDecoder()
                if let value = try? decoder.decode(payload), let m = value["m"] {
                    if let utPex = m[PeerExchange.extensionName]?.integerValue {
                        remotePexIDs[key] = UInt8(utPex)
                    }
                }
                if let metaEx = metadataExchange {
                    let result = await metaEx.handleExtendedMessage(id: extID, payload: payload)
                    await processMetadataResult(result, key: key)
                }
            } else if extID == localPexID {
                // Inbound PEX message (BEP-11)
                if !isPrivate {
                    let decoded = PeerExchange.decode(payload: payload)
                    await addPeers(decoded.added.map { ($0.address, $0.port) })
                }
            } else if let metaEx = metadataExchange {
                let result = await metaEx.handleExtendedMessage(id: extID, payload: payload)
                await processMetadataResult(result, key: key)
            }

        case .request(let index, let begin, let length):
            let pIndex = Int(index)
            let isAmChoking = await state.amChoking
            let isFast = connections[key]?.supportsFastExtension == true
            let isAllowedFastByUs = await state.isMyAllowedFastPieceSent(pIndex)
            let canServe = !isAmChoking || (isFast && isAllowedFastByUs)

            if canServe, let dio = diskIO, let pm = pieceManager, await pm.hasPiece(pIndex) {
                if let block = try? await dio.readBlock(pieceIndex: pIndex, offset: Int(begin), length: Int(length)), !block.isEmpty {
                    try? await connections[key]?.send(.piece(index: index, begin: begin, block: block))
                    onBlockSent?(block.count)
                }
            } else if isFast {
                try? await connections[key]?.send(.rejectRequest(index: index, begin: begin, length: length))
            }

        default:
            break
        }
    }

    private func processMetadataResult(_ result: MetadataExchange.Result, key: String) async {
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

    /// Periodic loop broadcasting BEP-11 Peer Exchange updates.
    public func startPEXLoop() {
        guard !isPrivate, pexBroadcastTask == nil else { return }
        pexBroadcastTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard let self else { break }
                await self.broadcastPEX()
            }
        }
    }

    private func broadcastPEX() async {
        guard !isPrivate else { return }
        let addedList = Array(pexAddedSinceLast)
        let droppedList = Array(pexDroppedSinceLast)
        pexAddedSinceLast.removeAll()
        pexDroppedSinceLast.removeAll()

        guard !addedList.isEmpty || !droppedList.isEmpty else { return }
        let payload = PeerExchange.encode(added: addedList, dropped: droppedList)

        for (key, remoteID) in remotePexIDs {
            guard let conn = connections[key] else { continue }
            try? await conn.send(.extended(id: remoteID, payload: payload))
        }
    }

    private func fillRequests(for key: String) async {
        guard let state = peerStates[key],
              let pm = pieceManager,
              let conn = connections[key] else { return }

        let peerChoking = await state.getPeerChoking()
        let allowedFast = await state.allowedFastPieces
        let isFast = conn.supportsFastExtension

        // If choked and not fast extension, or choked and no allowed fast pieces, cannot request
        if peerChoking && (!isFast || allowedFast.isEmpty) { return }

        let completed = await pm.getCompleted()
        let inProgress = await pm.getInProgress()
        let peerBF = await state.getPeerBitfield()

        var triedPieces: Set<Int> = []

        while await state.canRequest {
            var targetPiece: Int? = nil

            if peerChoking {
                // When choked, we can ONLY request pieces that the peer marked as Allowed Fast
                for afPiece in allowedFast {
                    if !completed.get(afPiece) && peerBF.get(afPiece) && !triedPieces.contains(afPiece) {
                        if !(await isPieceFullyRequested(afPiece, pieceManager: pm)) {
                            targetPiece = afPiece
                            break
                        } else {
                            triedPieces.insert(afPiece)
                        }
                    }
                }
            } else {
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
                offset += length
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
        connectingKeys.remove(key)
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
        connectedPeers.count > 0 ? connectedPeers.count : connections.count
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

    /// Broadcast our complete bitfield to all peers.
    public func broadcastBitfield(_ bitfield: Bitfield) async {
        guard !bitfield.isEmpty else { return }
        let msg = PeerMessage.bitfield(bitfield.toData())
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
        pexBroadcastTask?.cancel()
        pexBroadcastTask = nil
        for conn in connections.values {
            try? await conn.close()
        }
        connections.removeAll()
        peerInfos.removeAll()
        peerStates.removeAll()
        connectedPeers.removeAll()
        globalPendingRequests.removeAll()
        remotePexIDs.removeAll()
    }
}
