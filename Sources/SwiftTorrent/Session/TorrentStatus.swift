import Foundation

/// Current state of a torrent.
public enum TorrentState: String, Sendable, Codable, Equatable {
    case checkingFiles = "checking_files"
    case downloadingMetadata = "downloading_metadata"
    case downloading
    case seeding
    case paused
    case stopped
    case offloadedToTimeCapsule = "offloaded_to_timecapsule"
    case error
}

/// A snapshot of a torrent's current status.
public struct TorrentStatus: Identifiable, Equatable, Sendable {
    public var id: InfoHash { infoHash }
    public let infoHash: InfoHash
    public let name: String
    public let state: TorrentState
    public let progress: Double        // 0.0 to 1.0
    public let downloadRate: Double    // bytes per second
    public let uploadRate: Double
    public let totalDownloaded: Int64
    public let totalUploaded: Int64
    public let totalSize: Int64
    public let numPeers: Int
    public let numSeeds: Int
    public let piecesCompleted: Int
    public let piecesTotal: Int
    public let isStreaming: Bool

    public init(
        infoHash: InfoHash,
        name: String,
        state: TorrentState,
        progress: Double,
        downloadRate: Double,
        uploadRate: Double,
        totalDownloaded: Int64,
        totalUploaded: Int64,
        totalSize: Int64,
        numPeers: Int,
        numSeeds: Int,
        piecesCompleted: Int,
        piecesTotal: Int,
        isStreaming: Bool = false
    ) {
        self.infoHash = infoHash
        self.name = name
        self.state = state
        self.progress = progress
        self.downloadRate = downloadRate
        self.uploadRate = uploadRate
        self.totalDownloaded = totalDownloaded
        self.totalUploaded = totalUploaded
        self.totalSize = totalSize
        self.numPeers = numPeers
        self.numSeeds = numSeeds
        self.piecesCompleted = piecesCompleted
        self.piecesTotal = piecesTotal
        self.isStreaming = isStreaming
    }
}
