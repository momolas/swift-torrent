import Foundation

/// HTTP tracker client (BEP-3).
public struct HTTPTracker: Sendable {
    public let announceURL: String

    public init(announceURL: String) {
        self.announceURL = announceURL
    }

    /// Announce to the tracker.
    public func announce(params: AnnounceParams) async throws -> AnnounceResponse {
        guard var components = URLComponents(string: announceURL) else {
            throw TrackerError.invalidURL
        }

        // Properly URL encode binary fields without double percent-encoding
        let infoHashEncoded = params.infoHash.urlEncoded
        let peerIDEncoded = params.peerID.map { byte -> String in
            switch byte {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x2D, 0x2E, 0x5F, 0x7E:
                return String(UnicodeScalar(byte))
            default:
                let hi = byte >> 4
                let lo = byte & 0x0F
                return "%" + String(hi, radix: 16).uppercased() + String(lo, radix: 16).uppercased()
            }
        }.joined()

        var queryParts = [
            "info_hash=\(infoHashEncoded)",
            "peer_id=\(peerIDEncoded)",
            "port=\(params.port)",
            "uploaded=\(params.uploaded)",
            "downloaded=\(params.downloaded)",
            "left=\(params.left)",
            "compact=1",
            "numwant=\(params.numWant)"
        ]
        if let event = params.event {
            queryParts.append("event=\(event)")
        }

        let query = queryParts.joined(separator: "&")
        if let existing = components.percentEncodedQuery, !existing.isEmpty {
            components.percentEncodedQuery = existing + "&" + query
        } else {
            components.percentEncodedQuery = query
        }

        guard let url = components.url else {
            throw TrackerError.invalidURL
        }

        let (data, _) = try await URLSession.shared.data(from: url)
        return try parseAnnounceResponse(data)
    }

    /// Scrape the tracker (BEP-48).
    public func scrape(infoHash: InfoHash) async throws -> ScrapeInfo {
        var scrapeURLString = announceURL
        if scrapeURLString.contains("/announce") {
            scrapeURLString = scrapeURLString.replacing("/announce", with: "/scrape")
        } else {
            throw TrackerError.invalidURL
        }

        guard var components = URLComponents(string: scrapeURLString) else {
            throw TrackerError.invalidURL
        }

        let query = "info_hash=\(infoHash.urlEncoded)"
        if let existing = components.percentEncodedQuery, !existing.isEmpty {
            components.percentEncodedQuery = existing + "&" + query
        } else {
            components.percentEncodedQuery = query
        }

        guard let url = components.url else {
            throw TrackerError.invalidURL
        }

        let (data, _) = try await URLSession.shared.data(from: url)
        let decoder = BencodeDecoder()
        let value = try decoder.decode(data)

        if let failure = value["failure reason"]?.utf8String {
            throw TrackerError.failure(failure)
        }

        guard let files = value["files"]?.dictionaryValue else {
            throw TrackerError.invalidResponse
        }

        // Try to match the infoHash in the files dictionary
        for (keyData, fileDict) in files {
            // Key can be raw 20 bytes or hex string
            let matches = (keyData == infoHash.bytes)
                || (String(data: keyData, encoding: .utf8)?.lowercased() == infoHash.hex.lowercased())
                || files.count == 1

            if matches {
                let seeders = fileDict["complete"]?.integerValue.map(Int.init) ?? 0
                let leechers = fileDict["incomplete"]?.integerValue.map(Int.init) ?? 0
                let completed = fileDict["downloaded"]?.integerValue.map(Int.init) ?? 0
                return ScrapeInfo(seeders: seeders, leechers: leechers, completed: completed)
            }
        }

        throw TrackerError.invalidResponse
    }

    private func parseAnnounceResponse(_ data: Data) throws -> AnnounceResponse {
        let decoder = BencodeDecoder()
        let value = try decoder.decode(data)

        if let failure = value["failure reason"]?.utf8String {
            throw TrackerError.failure(failure)
        }

        let interval = value["interval"]?.integerValue.map(Int.init) ?? 1800
        let seeders = value["complete"]?.integerValue.map(Int.init) ?? 0
        let leechers = value["incomplete"]?.integerValue.map(Int.init) ?? 0

        var peers: [(String, UInt16)] = []

        if let peersData = value["peers"]?.stringValue {
            // Compact format: 6 bytes per peer (4 IP + 2 port)
            var offset = 0
            while offset + 6 <= peersData.count {
                let start = peersData.startIndex + offset
                let ip = "\(peersData[start]).\(peersData[start+1]).\(peersData[start+2]).\(peersData[start+3])"
                let port = UInt16(peersData[start+4]) << 8 | UInt16(peersData[start+5])
                peers.append((ip, port))
                offset += 6
            }
        } else if let peersList = value["peers"]?.listValue {
            // Dictionary format
            for peerValue in peersList {
                if let ip = peerValue["ip"]?.utf8String,
                   let port = peerValue["port"]?.integerValue {
                    peers.append((ip, UInt16(port)))
                }
            }
        }

        return AnnounceResponse(
            interval: interval, seeders: seeders, leechers: leechers, peers: peers
        )
    }
}

public struct ScrapeInfo: Sendable, Equatable {
    public let seeders: Int
    public let leechers: Int
    public let completed: Int

    public init(seeders: Int, leechers: Int, completed: Int) {
        self.seeders = seeders
        self.leechers = leechers
        self.completed = completed
    }
}

public struct AnnounceParams: Sendable {
    public let infoHash: InfoHash
    public let peerID: Data
    public let port: UInt16
    public let uploaded: Int64
    public let downloaded: Int64
    public let left: Int64
    public let numWant: Int
    public let event: String?  // "started", "stopped", "completed"

    public init(infoHash: InfoHash, peerID: Data, port: UInt16,
                uploaded: Int64 = 0, downloaded: Int64 = 0, left: Int64,
                numWant: Int = 50, event: String? = nil) {
        self.infoHash = infoHash
        self.peerID = peerID
        self.port = port
        self.uploaded = uploaded
        self.downloaded = downloaded
        self.left = left
        self.numWant = numWant
        self.event = event
    }
}

public struct AnnounceResponse: Sendable {
    public let interval: Int
    public let seeders: Int
    public let leechers: Int
    public let peers: [(String, UInt16)]
}

public enum TrackerError: Error, Equatable {
    case invalidURL
    case failure(String)
    case invalidResponse
    case connectionFailed
}
