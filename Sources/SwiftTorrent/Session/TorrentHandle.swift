import Foundation
import NIOCore
import NIOPosix

/// Errors thrown by TorrentHandle wait methods.
public enum TorrentError: Error {
    case timeout
}

/// Per-torrent controller tying peers, pieces, and disk together.
public actor TorrentHandle {
    public let infoHash: InfoHash
    private var info: TorrentInfo?
    private let magnetLink: MagnetLink?
    private let savePath: String
    private let peerID: Data
    private let group: EventLoopGroup

    private var peerManager: PeerManager
    private var pieceManager: PieceManager?
    private var piecePicker: PiecePicker?
    private var diskIO: DiskIO?
    private var trackerManager: TrackerManager?
    private var state: TorrentState = .paused
    private var totalDownloaded: Int64 = 0
    private var totalUploaded: Int64 = 0
    private var downloadedBytesWindow: Int64 = 0
    private var downloadRate: Double = 0
    private var uploadRate: Double = 0
    private var reannounceTask: Task<Void, Never>?
    private var downloadMonitorTask: Task<Void, Never>?
    private var metadataExchange: MetadataExchange?
    private var metadataContinuations: [UInt64: CheckedContinuation<TorrentInfo, Error>] = [:]
    private var completionContinuations: [UInt64: CheckedContinuation<Void, Error>] = [:]
    private var nextWaitID: UInt64 = 0
    private let settings: SessionSettings
    private var resumeData: ResumeData?

    public init(params: AddTorrentParams, settings: SessionSettings, group: EventLoopGroup) {
        let hash = params.infoHash!
        self.infoHash = hash
        self.info = params.torrentInfo
        self.magnetLink = params.magnetLink
        self.savePath = params.savePath ?? settings.savePath
        self.peerID = generatePeerID()
        self.group = group
        self.settings = settings
        self.resumeData = params.resumeData
        self.peerManager = PeerManager(
            infoHash: hash.bytes, peerID: peerID, group: group,
            maxConnections: settings.maxConnectionsPerTorrent
        )

        if let magnet = params.magnetLink, !magnet.trackers.isEmpty {
            let tiers = magnet.trackers.map { [$0] }
            self.trackerManager = TrackerManager(tiers: tiers, group: group)
        }
    }

    private func setupDownloadComponents(info: TorrentInfo) async {
        self.info = info
        let pm = PieceManager(info: info)
        let pp = PiecePicker(pieceCount: info.pieceCount)
        let fs = FileStorage(info: info)
        let dio = DiskIO(basePath: savePath, fileStorage: fs, usePartExtension: settings.usePartExtension)
        self.pieceManager = pm
        self.piecePicker = pp
        self.diskIO = dio

        if self.trackerManager == nil {
            self.trackerManager = TrackerManager(info: info, group: group)
        }

        await peerManager.configure(
            pieceManager: pm, piecePicker: pp, diskIO: dio,
            pieceCount: info.pieceCount
        )

        await peerManager.setOnPieceCompleted { [weak self] pieceIndex in
            Task { await self?.handlePieceCompleted(pieceIndex) }
        }
        await peerManager.setOnBlockReceived { [weak self] bytes in
            Task { await self?.handleBlockReceived(bytes) }
        }
    }

    private func checkExistingFilesOrResume(info: TorrentInfo, pm: PieceManager, dio: DiskIO) async {
        // Fast resume: if resumeData was provided and files exist on disk, use it directly
        if let resume = self.resumeData, await dio.hasExistingFiles() {
            await pm.setCompletedBitfield(resume.completedPieces)
            let computed = await pm.completedBytes()
            self.totalDownloaded = max(resume.downloaded, computed)
            self.totalUploaded = resume.uploaded
            let isComplete = await pm.isComplete()
            if isComplete {
                try? await dio.finalizeFiles()
                transitionToSeeding()
            }
            return
        }

        // Full disk check: if files exist on disk without resume data (e.g. torrent was re-added)
        guard await dio.hasExistingFiles() else { return }

        let previousState = state
        state = .checkingFiles

        let pieceCount = info.pieceCount
        for i in 0..<pieceCount {
            if let data = try? await dio.readPiece(index: i), !data.isEmpty {
                _ = await pm.verifyPieceFromDisk(index: i, data: data)
            }
        }

        self.totalDownloaded = await pm.completedBytes()

        let isComplete = await pm.isComplete()
        if isComplete {
            try? await dio.finalizeFiles()
            transitionToSeeding()
        } else {
            state = (previousState == .paused) ? .paused : .downloading
        }
    }

    private func handlePieceCompleted(_ pieceIndex: Int) async {
        // Piece verified and written to disk
    }

    private func handleBlockReceived(_ bytes: Int) {
        totalDownloaded += Int64(bytes)
        downloadedBytesWindow += Int64(bytes)
    }

    private func consumeWindowBytes() -> Int64 {
        let bytes = downloadedBytesWindow
        downloadedBytesWindow = 0
        return bytes
    }

    /// Complete initialization for .torrent-file init path (must be called after init).
    internal func finishInitialization() async {
        if let info = self.info {
            await setupDownloadComponents(info: info)
            if let pm = self.pieceManager, let dio = self.diskIO {
                await checkExistingFilesOrResume(info: info, pm: pm, dio: dio)
            }
        }
    }

    /// Start downloading.
    public func start() async throws {
        guard state == .paused || state == .stopped || state == .checkingFiles else { return }

        if info != nil {
            let isComplete = await pieceManager?.isComplete() ?? false
            if isComplete {
                state = .seeding
            } else {
                state = .downloading
                try? await diskIO?.allocateFiles()
                startDownloadMonitor()
            }
        } else if magnetLink != nil {
            state = .downloadingMetadata
            // Set up metadata exchange
            let metaEx = MetadataExchange(infoHash: infoHash)
            self.metadataExchange = metaEx
            await peerManager.configureMagnet(metadataExchange: metaEx)
            await peerManager.setOnMetadataReceived { [weak self] info in
                Task { await self?.onMetadataReceived(info: info) }
            }
        } else {
            state = .downloading
        }

        // Announce to trackers
        if let trackerMgr = trackerManager {
            let left = getRemainingBytes()
            let params = AnnounceParams(
                infoHash: infoHash, peerID: peerID, port: settings.listenPort,
                uploaded: totalUploaded, downloaded: totalDownloaded,
                left: left, event: "started"
            )
            await announceToAllTrackers(trackerMgr: trackerMgr, params: params)
            startReannounceLoop(trackerMgr: trackerMgr)
        }
    }

    private func onMetadataReceived(info: TorrentInfo) async {
        await setupDownloadComponents(info: info)
        if let pm = self.pieceManager, let dio = self.diskIO {
            await checkExistingFilesOrResume(info: info, pm: pm, dio: dio)
        }

        let isComplete = await pieceManager?.isComplete() ?? false
        if isComplete {
            state = .seeding
        } else {
            state = .downloading
            try? await diskIO?.allocateFiles()
            startDownloadMonitor()
        }

        // Resume all waiting metadata continuations
        let conts = metadataContinuations
        metadataContinuations.removeAll()
        for (_, cont) in conts {
            cont.resume(returning: info)
        }
    }

    private func startDownloadMonitor() {
        downloadMonitorTask = Task { [weak self] in
            var lastSampleTime = Date()

            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { break }

                let now = Date()
                let elapsed = now.timeIntervalSince(lastSampleTime)
                if elapsed > 0 {
                    let bytesInWindow = await self.consumeWindowBytes()
                    let instantRate = Double(bytesInWindow) / elapsed
                    let currentRate = await self.downloadRate
                    // Exponential moving average filter (EMA) to prevent sawtooth fluctuation
                    let smoothedRate: Double
                    if bytesInWindow == 0 && currentRate < 4096 {
                        smoothedRate = 0
                    } else if currentRate == 0 {
                        smoothedRate = instantRate
                    } else {
                        smoothedRate = currentRate * 0.70 + instantRate * 0.30
                    }
                    await self.setDownloadRate(smoothedRate)
                    lastSampleTime = now
                }

                let complete = await self.checkCompletion()
                if complete {
                    await self.transitionToSeeding()
                    break
                }
                await self.peerManager.checkTimeouts()
            }
        }
    }

    private func setDownloadRate(_ rate: Double) {
        self.downloadRate = rate
    }

    private func checkCompletion() async -> Bool {
        guard let pm = pieceManager else { return false }
        return await pm.isComplete()
    }

    private func transitionToSeeding() {
        state = .seeding
        downloadRate = 0
        downloadMonitorTask?.cancel()

        // Resume all waiting completion continuations
        let conts = completionContinuations
        completionContinuations.removeAll()
        for (_, cont) in conts {
            cont.resume()
        }
    }

    /// Announce to all tracker tiers concurrently.
    private func announceToAllTrackers(trackerMgr: TrackerManager, params: AnnounceParams) async {
        if let response = try? await trackerMgr.announce(params: params) {
            for (address, port) in response.peers {
                await peerManager.addPeer(address: address, port: port)
            }
        }
    }

    /// Periodically re-announce to trackers.
    private func startReannounceLoop(trackerMgr: TrackerManager) {
        reannounceTask = Task { [weak self] in
            while !Task.isCancelled {
                let interval = await trackerMgr.getInterval()
                try? await Task.sleep(for: .seconds(max(interval, 60)))
                guard let self, !Task.isCancelled else { break }

                let left = await self.getRemainingBytes()
                let infoHash = await self.infoHash
                let peerID = await self.peerID
                let uploaded = await self.totalUploaded
                let downloaded = await self.totalDownloaded
                let params = AnnounceParams(
                    infoHash: infoHash, peerID: peerID, port: self.settings.listenPort,
                    uploaded: uploaded, downloaded: downloaded,
                    left: left
                )
                if let response = try? await trackerMgr.announce(params: params) {
                    for (address, port) in response.peers {
                        await self.peerManager.addPeer(address: address, port: port)
                    }
                }
            }
        }
    }

    private func getRemainingBytes() -> Int64 {
        max(0, (info?.totalSize ?? 0) - totalDownloaded)
    }

    /// Pause the torrent and disconnect all active peer sockets.
    public func pause() async {
        state = .paused
        downloadRate = 0
        uploadRate = 0
        reannounceTask?.cancel()
        downloadMonitorTask?.cancel()
        reannounceTask = nil
        downloadMonitorTask = nil
        await peerManager.disconnectAll()
    }

    /// Stop the torrent and cleanup resources.
    public func stop() async {
        await pause()
        state = .stopped
    }

    /// Real-time stream of status updates for SwiftUI.
    public func statusStream(interval: TimeInterval = 1.0) -> AsyncStream<TorrentStatus> {
        AsyncStream { continuation in
            let task = Task {
                while !Task.isCancelled {
                    let st = await self.status()
                    continuation.yield(st)
                    try? await Task.sleep(for: .seconds(interval))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    /// Resume the torrent.
    public func resume() async throws {
        try await start()
    }

    /// Get current status snapshot.
    public func status() async -> TorrentStatus {
        let progress = await pieceManager?.progress() ?? 0
        let completed = await pieceManager?.getCompleted()
        let name: String
        if let info = info {
            name = info.name
        } else if let dn = magnetLink?.displayName {
            name = dn
        } else {
            name = "Unknown"
        }
        return TorrentStatus(
            infoHash: infoHash,
            name: name,
            state: state,
            progress: progress,
            downloadRate: downloadRate,
            uploadRate: uploadRate,
            totalDownloaded: totalDownloaded,
            totalUploaded: totalUploaded,
            totalSize: info?.totalSize ?? 0,
            numPeers: await peerManager.connectionCount,
            numSeeds: 0,
            piecesCompleted: completed?.popcount ?? 0,
            piecesTotal: info?.pieceCount ?? 0
        )
    }

    /// Returns connected peers for UI inspection.
    public func getPeers() async -> [PeerInfo] {
        await peerManager.getPeers()
    }

    /// Returns the completed pieces bitfield for UI piece grid inspection.
    public func getBitfield() async -> Bitfield? {
        await pieceManager?.getCompleted()
    }

    /// Returns the file entries for this torrent, or nil if metadata is not yet available.
    public func getFiles() -> [TorrentInfo.FileEntry]? {
        info?.files
    }

    /// Returns the save path for this torrent.
    public func getSavePath() -> String {
        savePath
    }

    /// Returns the name of the torrent or magnet link.
    public func getTorrentName() -> String {
        info?.name ?? magnetLink?.displayName ?? ""
    }

    /// Generate resume data for saving state.
    public func generateResumeData() async -> ResumeData? {
        guard let completed = await pieceManager?.getCompleted() else { return nil }
        return ResumeData(
            infoHash: infoHash, completedPieces: completed,
            uploaded: totalUploaded, downloaded: totalDownloaded,
            savePath: savePath
        )
    }

    /// Wait until metadata is available, or return immediately if already present.
    public func waitForMetadata(timeout seconds: Int) async throws -> TorrentInfo {
        if let info = self.info {
            return info
        }

        let id = nextWaitID
        nextWaitID += 1

        return try await withCheckedThrowingContinuation { continuation in
            metadataContinuations[id] = continuation

            Task { [weak self] in
                try? await Task.sleep(for: .seconds(seconds))
                guard let self else { return }
                if let cont = await self.removeMetadataContinuation(id: id) {
                    cont.resume(throwing: TorrentError.timeout)
                }
            }
        }
    }

    private func removeMetadataContinuation(id: UInt64) -> CheckedContinuation<TorrentInfo, Error>? {
        metadataContinuations.removeValue(forKey: id)
    }

    /// Wait until all pieces are downloaded, or return immediately if already complete.
    public func waitForCompletion(timeout seconds: Int) async throws {
        if state == .seeding {
            return
        }

        let id = nextWaitID
        nextWaitID += 1

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            completionContinuations[id] = continuation

            Task { [weak self] in
                try? await Task.sleep(for: .seconds(seconds))
                guard let self else { return }
                if let cont = await self.removeCompletionContinuation(id: id) {
                    cont.resume(throwing: TorrentError.timeout)
                }
            }
        }
    }

    private func removeCompletionContinuation(id: UInt64) -> CheckedContinuation<Void, Error>? {
        completionContinuations.removeValue(forKey: id)
    }
}
