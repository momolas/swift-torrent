import Foundation

/// Coordinates multiple trackers with tier support.
public actor TrackerManager {
    private var tiers: [[String]]
    private var lastResponse: AnnounceResponse?
    private var announceInterval: Int = 1800
    private var trackerEntries: [String: TrackerEntry] = [:]
    public var isBlocked: (@Sendable (String) -> Bool)? {
        didSet {
            updateBlockedStates()
        }
    }

    public init(tiers: [[String]], group: Any? = nil, isBlocked: (@Sendable (String) -> Bool)? = nil) {
        self.tiers = tiers
        self.isBlocked = isBlocked
        for tier in tiers {
            for url in tier {
                let blocked = isBlocked?(url) ?? false
                self.trackerEntries[url] = TrackerEntry(urlString: url, status: blocked ? .blocked : .notContacted)
            }
        }
    }

    /// Convenience: create from TorrentInfo.
    public init(info: TorrentInfo, group: Any? = nil, isBlocked: (@Sendable (String) -> Bool)? = nil) {
        var tiers = info.announceList
        if tiers.isEmpty, let url = info.announceURL {
            tiers = [[url]]
        }
        self.tiers = tiers
        self.isBlocked = isBlocked
        for tier in tiers {
            for url in tier {
                let blocked = isBlocked?(url) ?? false
                self.trackerEntries[url] = TrackerEntry(urlString: url, status: blocked ? .blocked : .notContacted)
            }
        }
    }

    public func setIsBlocked(_ block: (@Sendable (String) -> Bool)?) {
        self.isBlocked = block
    }

    private func updateBlockedStates() {
        guard let isBlocked else { return }
        for (url, _) in trackerEntries {
            if isBlocked(url) {
                trackerEntries[url]?.status = .blocked
            }
        }
    }

    public func addTracker(urlString: String) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if trackerEntries[trimmed] == nil {
            tiers.append([trimmed])
            let blocked = isBlocked?(trimmed) ?? false
            trackerEntries[trimmed] = TrackerEntry(urlString: trimmed, status: blocked ? .blocked : .notContacted)
        }
    }

    public func getTrackerEntries() -> [TrackerEntry] {
        // Return in order of tiers
        var ordered: [TrackerEntry] = []
        var seen = Set<String>()
        for tier in tiers {
            for url in tier {
                if !seen.contains(url), let entry = trackerEntries[url] {
                    seen.insert(url)
                    ordered.append(entry)
                }
            }
        }
        return ordered
    }

    /// Announce to all tracker tiers, returning the first successful response.
    public func announce(params: AnnounceParams) async throws -> AnnounceResponse {
        for tier in tiers {
            for urlString in tier {
                if let isBlocked, isBlocked(urlString) {
                    trackerEntries[urlString]?.status = .blocked
                    continue
                }
                trackerEntries[urlString]?.status = .updating
                do {
                    let response: AnnounceResponse
                    if urlString.hasPrefix("http://") || urlString.hasPrefix("https://") {
                        let tracker = HTTPTracker(announceURL: urlString)
                        response = try await tracker.announce(params: params)
                    } else if urlString.hasPrefix("udp://") {
                        guard let components = URLComponents(string: urlString),
                              let host = components.host,
                              let port = components.port else {
                            trackerEntries[urlString]?.status = .error
                            trackerEntries[urlString]?.lastError = "Invalid UDP URL format"
                            continue
                        }
                        let tracker = UDPTracker(host: host, port: port)
                        response = try await tracker.announce(params: params)
                    } else {
                        trackerEntries[urlString]?.status = .error
                        trackerEntries[urlString]?.lastError = "Unsupported protocol"
                        continue
                    }

                    trackerEntries[urlString]?.status = .working
                    trackerEntries[urlString]?.peersCount = response.peers.count
                    trackerEntries[urlString]?.seeders = response.seeders
                    trackerEntries[urlString]?.leechers = response.leechers
                    trackerEntries[urlString]?.nextAnnounceDate = Date().addingTimeInterval(TimeInterval(response.interval))
                    trackerEntries[urlString]?.lastError = nil

                    lastResponse = response
                    announceInterval = response.interval
                    return response
                } catch {
                    trackerEntries[urlString]?.status = .error
                    trackerEntries[urlString]?.lastError = error.localizedDescription
                    trackerEntries[urlString]?.nextAnnounceDate = Date().addingTimeInterval(60)
                    continue // Try next tracker in tier
                }
            }
        }
        throw TrackerError.connectionFailed
    }

    /// Announce across all available trackers concurrently to discover maximum peers.
    public func announceAll(params: AnnounceParams) async -> [(String, UInt16)] {
        var allPeers: [(String, UInt16)] = []
        var seenKeys: Set<String> = []

        let capturedIsBlocked = self.isBlocked

        typealias AnnounceResult = (urlString: String, peers: [(String, UInt16)], interval: Int, seeders: Int, leechers: Int, error: Error?)

        await withTaskGroup(of: AnnounceResult.self) { taskGroup in
            for tier in self.tiers {
                for urlString in tier {
                    if let isBlocked = capturedIsBlocked, isBlocked(urlString) {
                        continue
                    }
                    taskGroup.addTask {
                        do {
                            let response: AnnounceResponse
                            if urlString.hasPrefix("http://") || urlString.hasPrefix("https://") {
                                let tracker = HTTPTracker(announceURL: urlString)
                                response = try await tracker.announce(params: params)
                            } else if urlString.hasPrefix("udp://") {
                                guard let components = URLComponents(string: urlString),
                                      let host = components.host,
                                      let port = components.port else {
                                    return (urlString, [], 0, 0, 0, TrackerError.invalidURL)
                                }
                                let tracker = UDPTracker(host: host, port: port)
                                response = try await tracker.announce(params: params)
                            } else {
                                return (urlString, [], 0, 0, 0, TrackerError.invalidURL)
                            }
                            return (urlString, response.peers, response.interval, response.seeders, response.leechers, nil)
                        } catch {
                            return (urlString, [], 0, 0, 0, error)
                        }
                    }
                }
            }

            for await result in taskGroup {
                if let error = result.error {
                    trackerEntries[result.urlString]?.status = .error
                    trackerEntries[result.urlString]?.lastError = error.localizedDescription
                    trackerEntries[result.urlString]?.nextAnnounceDate = Date().addingTimeInterval(60)
                } else {
                    trackerEntries[result.urlString]?.status = .working
                    trackerEntries[result.urlString]?.peersCount = result.peers.count
                    trackerEntries[result.urlString]?.seeders = result.seeders
                    trackerEntries[result.urlString]?.leechers = result.leechers
                    trackerEntries[result.urlString]?.nextAnnounceDate = Date().addingTimeInterval(TimeInterval(max(result.interval, 60)))
                    trackerEntries[result.urlString]?.lastError = nil

                    for peer in result.peers {
                        let key = "\(peer.0):\(peer.1)"
                        if !seenKeys.contains(key) {
                            seenKeys.insert(key)
                            allPeers.append(peer)
                        }
                    }
                }
            }
        }

        // Update any blocked entries
        if let isBlocked = self.isBlocked {
            for (url, _) in trackerEntries {
                if isBlocked(url) {
                    trackerEntries[url]?.status = .blocked
                }
            }
        }

        return allPeers
    }

    /// Scrape across trackers for this torrent's infoHash (BEP 48 / BEP 15).
    public func scrape(infoHash: InfoHash) async -> [String: ScrapeInfo] {
        var results: [String: ScrapeInfo] = [:]

        await withTaskGroup(of: (String, ScrapeInfo?).self) { group in
            for tier in self.tiers {
                for urlString in tier {
                    if let isBlocked = self.isBlocked, isBlocked(urlString) { continue }
                    group.addTask {
                        if urlString.hasPrefix("http://") || urlString.hasPrefix("https://") {
                            let tracker = HTTPTracker(announceURL: urlString)
                            if let info = try? await tracker.scrape(infoHash: infoHash) {
                                return (urlString, info)
                            }
                        } else if urlString.hasPrefix("udp://") {
                            guard let components = URLComponents(string: urlString),
                                  let host = components.host,
                                  let port = components.port else { return (urlString, nil) }
                            let tracker = UDPTracker(host: host, port: port)
                            if let dict = try? await tracker.scrape(infoHashes: [infoHash]),
                               let info = dict[infoHash] {
                                return (urlString, info)
                            }
                        }
                        return (urlString, nil)
                    }
                }
            }

            for await (url, maybeInfo) in group {
                if let info = maybeInfo {
                    results[url] = info
                    trackerEntries[url]?.seeders = info.seeders
                    trackerEntries[url]?.leechers = info.leechers
                    trackerEntries[url]?.downloaded = info.completed
                    if trackerEntries[url]?.status != .working {
                        trackerEntries[url]?.status = .working
                    }
                }
            }
        }

        return results
    }

    public func getInterval() -> Int {
        announceInterval
    }
}

public struct TrackerEntry: Identifiable, Sendable, Equatable {
    public var id: String { urlString }
    public let urlString: String
    public var status: TrackerStatus
    public var seeders: Int
    public var leechers: Int
    public var downloaded: Int
    public var peersCount: Int
    public var nextAnnounceDate: Date?
    public var lastError: String?

    public enum TrackerStatus: String, Sendable, Equatable {
        case working = "Working"
        case updating = "Updating"
        case error = "Error"
        case blocked = "Blocked"
        case notContacted = "Queued"
    }

    public init(
        urlString: String,
        status: TrackerStatus = .notContacted,
        seeders: Int = 0,
        leechers: Int = 0,
        downloaded: Int = 0,
        peersCount: Int = 0,
        nextAnnounceDate: Date? = nil,
        lastError: String? = nil
    ) {
        self.urlString = urlString
        self.status = status
        self.seeders = seeders
        self.leechers = leechers
        self.downloaded = downloaded
        self.peersCount = peersCount
        self.nextAnnounceDate = nextAnnounceDate
        self.lastError = lastError
    }
}
