import Foundation

/// Configuration settings for a Session.
public struct SessionSettings: Sendable {
    public var listenPort: UInt16
    public var maxConnections: Int
    public var maxConnectionsPerTorrent: Int
    public var downloadRateLimit: Int  // bytes/sec, 0 = unlimited
    public var uploadRateLimit: Int
    public var dhtEnabled: Bool
    public var dhtPort: Int
    public var userAgent: String
    public var savePath: String
    public var usePartExtension: Bool
    public var maxUploadRatio: Double // 0.0 = unlimited, e.g. 1.0 = stop when uploaded == downloaded
    public var uploadMultiplier: Double // 1.0 = normal/honest, 12.0 = Momo L'As booster factor

    public init(
        listenPort: UInt16 = 6881,
        maxConnections: Int = 200,
        maxConnectionsPerTorrent: Int = 50,
        downloadRateLimit: Int = 0,
        uploadRateLimit: Int = 0,
        dhtEnabled: Bool = true,
        dhtPort: Int = 6881,
        userAgent: String = "SwiftTorrent/1.0",
        savePath: String = NSTemporaryDirectory(),
        usePartExtension: Bool = true,
        maxUploadRatio: Double = 0.0,
        uploadMultiplier: Double = 1.0
    ) {
        self.listenPort = listenPort
        self.maxConnections = maxConnections
        self.maxConnectionsPerTorrent = maxConnectionsPerTorrent
        self.downloadRateLimit = downloadRateLimit
        self.uploadRateLimit = uploadRateLimit
        self.dhtEnabled = dhtEnabled
        self.dhtPort = dhtPort
        self.userAgent = userAgent
        self.savePath = savePath
        self.usePartExtension = usePartExtension
        self.maxUploadRatio = maxUploadRatio
        self.uploadMultiplier = uploadMultiplier
    }
}
