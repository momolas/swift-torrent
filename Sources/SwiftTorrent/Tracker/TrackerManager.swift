import Foundation
import NIOCore

/// Coordinates multiple trackers with tier support.
public actor TrackerManager {
    private let tiers: [[String]]
    private let group: EventLoopGroup
    private var lastResponse: AnnounceResponse?
    private var announceInterval: Int = 1800
    public var isBlocked: (@Sendable (String) -> Bool)?

    public init(tiers: [[String]], group: EventLoopGroup) {
        self.tiers = tiers
        self.group = group
    }

    /// Convenience: create from TorrentInfo.
    public init(info: TorrentInfo, group: EventLoopGroup) {
        var tiers = info.announceList
        if tiers.isEmpty, let url = info.announceURL {
            tiers = [[url]]
        }
        self.tiers = tiers
        self.group = group
    }

    /// Announce to all tracker tiers, returning the first successful response.
    public func announce(params: AnnounceParams) async throws -> AnnounceResponse {
        for tier in tiers {
            for urlString in tier {
                if let isBlocked, isBlocked(urlString) {
                    continue
                }
                do {
                    let response: AnnounceResponse
                    if urlString.hasPrefix("http://") || urlString.hasPrefix("https://") {
                        let tracker = HTTPTracker(announceURL: urlString)
                        response = try await tracker.announce(params: params)
                    } else if urlString.hasPrefix("udp://") {
                        guard let components = URLComponents(string: urlString),
                              let host = components.host,
                              let port = components.port else {
                            continue
                        }
                        let tracker = UDPTracker(host: host, port: port, group: group)
                        response = try await tracker.announce(params: params)
                    } else {
                        continue
                    }
                    lastResponse = response
                    announceInterval = response.interval
                    return response
                } catch {
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

        let capturedGroup = self.group
        await withTaskGroup(of: [(String, UInt16)].self) { taskGroup in
            for tier in self.tiers {
                for urlString in tier {
                    if let isBlocked = self.isBlocked, isBlocked(urlString) { continue }
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
                                    return []
                                }
                                let tracker = UDPTracker(host: host, port: port, group: capturedGroup)
                                response = try await tracker.announce(params: params)
                            } else {
                                return []
                            }
                            return response.peers
                        } catch {
                            return []
                        }
                    }
                }
            }

            for await peers in taskGroup {
                for peer in peers {
                    let key = "\(peer.0):\(peer.1)"
                    if !seenKeys.contains(key) {
                        seenKeys.insert(key)
                        allPeers.append(peer)
                    }
                }
            }
        }

        return allPeers
    }

    public func getInterval() -> Int {
        announceInterval
    }
}
