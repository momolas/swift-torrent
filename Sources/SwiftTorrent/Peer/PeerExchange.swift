import Foundation

/// BEP-11 Peer Exchange (PEX) message builder, parser, and state manager.
public enum PeerExchange {
    public static let extensionName = "ut_pex"
    public static let defaultLocalExtensionID: UInt8 = 2

    // Flags for added.f
    public static let flagEncryption: UInt8 = 0x01
    public static let flagSeed: UInt8 = 0x02
    public static let flagUTP: UInt8 = 0x04
    public static let flagHolepunch: UInt8 = 0x08

    public struct PeerEntry: Sendable, Hashable {
        public let address: String
        public let port: UInt16
        public let isSeed: Bool

        public init(address: String, port: UInt16, isSeed: Bool = false) {
            self.address = address
            self.port = port
            self.isSeed = isSeed
        }
    }

    /// Encode a PEX message payload as a bencoded dictionary.
    public static func encode(
        added: [PeerEntry],
        dropped: [PeerEntry]
    ) -> Data {
        var addedData = Data()
        var flagsData = Data()
        for peer in added.prefix(50) { // Limit to 50 peers per BEP-11 recommendation
            if let compact = encodeCompactPeer(address: peer.address, port: peer.port) {
                addedData.append(compact)
                flagsData.append(peer.isSeed ? flagSeed : 0)
            }
        }

        var droppedData = Data()
        for peer in dropped.prefix(50) {
            if let compact = encodeCompactPeer(address: peer.address, port: peer.port) {
                droppedData.append(compact)
            }
        }

        var dict: [(key: Data, value: BencodeValue)] = []
        if !addedData.isEmpty {
            dict.append((key: Data("added".utf8), value: .string(addedData)))
            dict.append((key: Data("added.f".utf8), value: .string(flagsData)))
        }
        if !droppedData.isEmpty {
            dict.append((key: Data("dropped".utf8), value: .string(droppedData)))
        }

        let encoder = BencodeEncoder()
        return encoder.encode(.dictionary(dict))
    }

    /// Decode a bencoded PEX message payload into added and dropped peers.
    public static func decode(payload: Data) -> (added: [PeerEntry], dropped: [PeerEntry]) {
        let decoder = BencodeDecoder()
        guard let value = try? decoder.decode(payload), case .dictionary = value else {
            return ([], [])
        }

        var addedPeers: [PeerEntry] = []
        if let addedData = value["added"]?.stringValue {
            let flagsData = value["added.f"]?.stringValue ?? Data()
            addedPeers = parseCompactPeers(addedData, flags: flagsData)
        }

        var droppedPeers: [PeerEntry] = []
        if let droppedData = value["dropped"]?.stringValue {
            droppedPeers = parseCompactPeers(droppedData, flags: Data())
        }

        return (addedPeers, droppedPeers)
    }

    /// Parse compact 6-byte IPv4 addresses into PeerEntry items.
    public static func parseCompactPeers(_ data: Data, flags: Data) -> [PeerEntry] {
        var peers: [PeerEntry] = []
        let peerCount = data.count / 6
        for i in 0..<peerCount {
            let offset = data.startIndex + i * 6
            let ip = "\(data[offset]).\(data[offset + 1]).\(data[offset + 2]).\(data[offset + 3])"
            let port = (UInt16(data[offset + 4]) << 8) | UInt16(data[offset + 5])
            guard port > 0 else { continue }
            let flag = (i < flags.count) ? flags[flags.startIndex + i] : 0
            let isSeed = (flag & flagSeed) != 0
            peers.append(PeerEntry(address: ip, port: port, isSeed: isSeed))
        }
        return peers
    }

    /// Encode an IPv4 string and port into 6 bytes compact format.
    public static func encodeCompactPeer(address: String, port: UInt16) -> Data? {
        let parts = address.split(separator: ".")
        guard parts.count == 4 else { return nil }
        var data = Data(capacity: 6)
        for part in parts {
            guard let octet = UInt8(part) else { return nil }
            data.append(octet)
        }
        data.append(contentsOf: port.bigEndianBytes)
        return data
    }
}
