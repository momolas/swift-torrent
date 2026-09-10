import Foundation

/// Tracks per-peer protocol state for download orchestration.
public actor PeerState {
    public var amChoking: Bool = true
    public var amInterested: Bool = false
    public var peerChoking: Bool = true
    public var peerInterested: Bool = false
    public var peerBitfield: Bitfield
    public var supportsExtensions: Bool = false
    public var supportsFastExtension: Bool = false
    public var supportsDHT: Bool = false
    public private(set) var allowedFastPieces: Set<Int> = []
    public private(set) var myAllowedFastPiecesSent: Set<Int> = []
    public private(set) var suggestedPieces: Set<Int> = []

    /// Pending block requests: (pieceIndex, offset, length) → timestamp
    public struct BlockRequest: Hashable, Sendable {
        public let pieceIndex: Int
        public let offset: Int
        public let length: Int
    }
    private var pendingRequests: [BlockRequest: Date] = [:]
    public let maxPipelineDepth: Int

    public init(pieceCount: Int, maxPipelineDepth: Int = 16) {
        self.peerBitfield = Bitfield(count: pieceCount)
        self.maxPipelineDepth = maxPipelineDepth
    }

    public func getPeerBitfield() -> Bitfield {
        peerBitfield
    }

    public func getPeerChoking() -> Bool {
        peerChoking
    }

    public func getAmInterested() -> Bool {
        amInterested
    }

    public var pendingCount: Int {
        pendingRequests.count
    }

    public var canRequest: Bool {
        pendingRequests.count < maxPipelineDepth
    }

    public func getPendingRequests() -> [BlockRequest: Date] {
        pendingRequests
    }

    public func hasPending(_ request: BlockRequest) -> Bool {
        pendingRequests[request] != nil
    }

    public func setPeerBitfield(_ bf: Bitfield) {
        peerBitfield = bf
    }

    public func setHave(_ index: Int) {
        peerBitfield.set(index)
    }

    public func setPeerChoking(_ choking: Bool) {
        peerChoking = choking
    }

    public func setPeerInterested(_ interested: Bool) {
        peerInterested = interested
    }

    public func setAmChoking(_ choking: Bool) {
        amChoking = choking
    }

    public func setAmInterested(_ interested: Bool) {
        amInterested = interested
    }

    public func setCapabilities(extensions: Bool, fastExtension: Bool, dht: Bool) {
        self.supportsExtensions = extensions
        self.supportsFastExtension = fastExtension
        self.supportsDHT = dht
    }

    public func addPendingRequest(_ request: BlockRequest) {
        pendingRequests[request] = Date()
    }

    public func removePendingRequest(_ request: BlockRequest) {
        pendingRequests.removeValue(forKey: request)
    }

    public func addAllowedFastPiece(_ pieceIndex: Int) {
        allowedFastPieces.insert(pieceIndex)
    }

    public func isAllowedFast(_ pieceIndex: Int) -> Bool {
        allowedFastPieces.contains(pieceIndex)
    }

    public func addMyAllowedFastPieceSent(_ pieceIndex: Int) {
        myAllowedFastPiecesSent.insert(pieceIndex)
    }

    public func isMyAllowedFastPieceSent(_ pieceIndex: Int) -> Bool {
        myAllowedFastPiecesSent.contains(pieceIndex)
    }

    public func addSuggestedPiece(_ pieceIndex: Int) {
        suggestedPieces.insert(pieceIndex)
    }

    public func clearPendingRequests() {
        pendingRequests.removeAll()
    }

    /// Clear pending requests whose piece is NOT in allowedFastPieces, returning the dropped requests.
    public func clearPendingRequestsExceptAllowedFast() -> [BlockRequest] {
        var dropped: [BlockRequest] = []
        var remaining: [BlockRequest: Date] = [:]
        for (req, date) in pendingRequests {
            if allowedFastPieces.contains(req.pieceIndex) {
                remaining[req] = date
            } else {
                dropped.append(req)
            }
        }
        pendingRequests = remaining
        return dropped
    }

    /// Returns requests older than the given timeout interval.
    public func timedOutRequests(timeout: TimeInterval = 30) -> [BlockRequest] {
        let cutoff = Date().addingTimeInterval(-timeout)
        return pendingRequests.filter { $0.value < cutoff }.map(\.key)
    }
}
