import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Well-known DHT bootstrap nodes.
private let bootstrapNodes: [(String, Int)] = [
    ("router.bittorrent.com", 6881),
    ("dht.transmissionbt.com", 6881),
    ("router.utorrent.com", 6881),
    ("dht.aelitis.com", 6881),
]

/// A DHT node that handles KRPC queries (BEP-5).
public actor DHTNode {
    public let nodeID: NodeID
    private var routingTable: DHTRoutingTable
    private var storage: DHTStorage
    private var socketFD: Int32 = -1
    private var readSource: DispatchSourceRead?
    private let port: Int
    private let queue = DispatchQueue(label: "org.swifttorrent.dhtnode", qos: .utility)
    private var pendingQueries: [Data: CheckedContinuation<DHTMessage, Error>] = [:]

    public init(nodeID: NodeID = .random(), port: Int = 6881, group: Any? = nil) {
        self.nodeID = nodeID
        self.routingTable = DHTRoutingTable(ownID: nodeID)
        self.storage = DHTStorage()
        self.port = port
    }

    /// Start the DHT node, binding to a UDP port and bootstrapping.
    public func start() async throws {
        var boundFD: Int32 = -1
        let portsToTry = [port, port + 1, port + 2, port + 3, 0]

        for p in portsToTry {
            let fd = socket(AF_INET, SOCK_DGRAM, 0)
            guard fd >= 0 else { continue }

            var reuse: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(UInt16(p).bigEndian)
            addr.sin_addr.s_addr = INADDR_ANY

            let bindResult = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }

            if bindResult == 0 {
                // Set non-blocking
                let flags = fcntl(fd, F_GETFL, 0)
                _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
                boundFD = fd
                break
            } else {
                close(fd)
            }
        }

        guard boundFD >= 0 else {
            throw DHTMessageError.invalidMessage
        }

        self.socketFD = boundFD

        let source = DispatchSource.makeReadSource(fileDescriptor: boundFD, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var buffer = [UInt8](repeating: 0, count: 65535)
            var senderAddr = sockaddr_in()
            var senderLen = socklen_t(MemoryLayout<sockaddr_in>.size)

            let bytesRead = withUnsafeMutablePointer(to: &senderAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    recvfrom(boundFD, &buffer, buffer.count, 0, sa, &senderLen)
                }
            }

            guard bytesRead > 0 else { return }

            let data = Data(buffer[0..<bytesRead])
            var ipStr = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &senderAddr.sin_addr, &ipStr, socklen_t(INET_ADDRSTRLEN))
            let address = String(cString: ipStr)
            let port = UInt16(bigEndian: senderAddr.sin_port)

            if let message = try? DHTMessage.decode(from: data) {
                Task {
                    await self.handleIncomingMessage(message, from: address, port: port)
                }
            }
        }

        source.setCancelHandler {
            close(boundFD)
        }

        source.resume()
        self.readSource = source

        // Bootstrap: contact well-known nodes
        await bootstrap()
    }

    public func stop() {
        readSource?.cancel()
        readSource = nil
        socketFD = -1
    }

    /// Bootstrap by contacting well-known DHT nodes.
    private func bootstrap() async {
        for (host, port) in bootstrapNodes {
            if let ip = try? await resolveHostname(host) {
                do {
                    try await findNode(target: nodeID, to: ip, port: UInt16(port))
                } catch {
                    continue
                }
            }
        }
    }

    /// Handle an incoming DHT message.
    private func handleIncomingMessage(_ message: DHTMessage, from address: String, port: UInt16) {
        switch message {
        case .response(let txID, let values):
            if let cont = pendingQueries.removeValue(forKey: txID) {
                cont.resume(returning: message)
            }

            if let nodesData = values.first(where: { String(data: $0.key, encoding: .utf8) == "nodes" })?.value.stringValue {
                parseCompactNodes(nodesData)
            }

        case .query(let txID, let queryType, let args):
            handleQuery(txID: txID, queryType: queryType, args: args, from: address, port: port)

        case .error:
            break
        }
    }

    /// Handle incoming queries from other DHT nodes.
    private func handleQuery(txID: Data, queryType: DHTMessage.QueryType,
                            args: [(key: Data, value: BencodeValue)],
                            from address: String, port: UInt16) {
        // Extract sender's node ID
        if let idValue = args.first(where: { String(data: $0.key, encoding: .utf8) == "id" })?.value.stringValue,
           idValue.count == 20 {
            let senderID = NodeID(bytes: idValue)
            _ = routingTable.insert(DHTNodeEntry(id: senderID, address: address, port: port))
        }

        switch queryType {
        case .ping:
            let response = DHTMessage.response(transactionID: txID, values: [
                (key: Data("id".utf8), value: .string(nodeID.bytes))
            ])
            Task { try? await sendMessage(response, to: address, port: port) }

        case .findNode:
            let targetID: NodeID
            if let targetData = args.first(where: { String(data: $0.key, encoding: .utf8) == "target" })?.value.stringValue,
               targetData.count == 20 {
                targetID = NodeID(bytes: targetData)
            } else {
                targetID = nodeID
            }
            let closest = routingTable.closestNodes(to: targetID)
            let nodesData = encodeCompactNodes(closest)
            let response = DHTMessage.response(transactionID: txID, values: [
                (key: Data("id".utf8), value: .string(nodeID.bytes)),
                (key: Data("nodes".utf8), value: .string(nodesData)),
            ])
            Task { try? await sendMessage(response, to: address, port: port) }

        case .getPeers:
            if let hashData = args.first(where: { String(data: $0.key, encoding: .utf8) == "info_hash" })?.value.stringValue {
                let peers = storage.getPeers(infoHash: hashData)
                let token = Data((address + "secret").utf8.prefix(8))

                if !peers.isEmpty {
                    var peerValues: [BencodeValue] = []
                    for (paddr, pport) in peers {
                        var compact = Data()
                        for component in paddr.split(separator: ".") {
                            compact.append(UInt8(component) ?? 0)
                        }
                        compact.append(contentsOf: pport.bigEndianBytes)
                        peerValues.append(.string(compact))
                    }
                    let response = DHTMessage.response(transactionID: txID, values: [
                        (key: Data("id".utf8), value: .string(nodeID.bytes)),
                        (key: Data("token".utf8), value: .string(token)),
                        (key: Data("values".utf8), value: .list(peerValues)),
                    ])
                    Task { try? await sendMessage(response, to: address, port: port) }
                } else {
                    let targetID = hashData.count == 20 ? NodeID(bytes: hashData) : nodeID
                    let closest = routingTable.closestNodes(to: targetID)
                    let nodesData = encodeCompactNodes(closest)
                    let response = DHTMessage.response(transactionID: txID, values: [
                        (key: Data("id".utf8), value: .string(nodeID.bytes)),
                        (key: Data("token".utf8), value: .string(token)),
                        (key: Data("nodes".utf8), value: .string(nodesData)),
                    ])
                    Task { try? await sendMessage(response, to: address, port: port) }
                }
            }

        case .announcePeer:
            if let hashData = args.first(where: { String(data: $0.key, encoding: .utf8) == "info_hash" })?.value.stringValue,
               let peerPort = args.first(where: { String(data: $0.key, encoding: .utf8) == "port" })?.value.integerValue {
                storage.addPeer(infoHash: hashData, address: address, port: UInt16(peerPort))
            }
            let response = DHTMessage.response(transactionID: txID, values: [
                (key: Data("id".utf8), value: .string(nodeID.bytes))
            ])
            Task { try? await sendMessage(response, to: address, port: port) }
        }
    }

    /// Send a query and wait for a response.
    public func sendAndWait(_ msg: DHTMessage, to address: String, port: UInt16, timeout: Duration = .seconds(5)) async throws -> DHTMessage {
        guard case .query(let txID, _, _) = msg else {
            throw DHTMessageError.invalidMessage
        }
        try await sendMessage(msg, to: address, port: port)

        return try await withCheckedThrowingContinuation { continuation in
            self.pendingQueries[txID] = continuation

            Task {
                try? await Task.sleep(for: timeout)
                if let cont = self.pendingQueries.removeValue(forKey: txID) {
                    cont.resume(throwing: DHTMessageError.invalidMessage)
                }
            }
        }
    }

    /// Send a ping query.
    public func ping(to address: String, port: UInt16) async throws {
        let txID = generateTransactionID()
        let msg = DHTMessage.query(
            transactionID: txID,
            queryType: .ping,
            arguments: [
                (key: Data("id".utf8), value: .string(nodeID.bytes))
            ]
        )
        try await sendMessage(msg, to: address, port: port)
    }

    /// Send a find_node query.
    public func findNode(target: NodeID, to address: String, port: UInt16) async throws {
        let txID = generateTransactionID()
        let msg = DHTMessage.query(
            transactionID: txID,
            queryType: .findNode,
            arguments: [
                (key: Data("id".utf8), value: .string(nodeID.bytes)),
                (key: Data("target".utf8), value: .string(target.bytes)),
            ]
        )
        try await sendMessage(msg, to: address, port: port)
    }

    /// Send a get_peers query.
    public func getPeers(infoHash: InfoHash, to address: String, port: UInt16) async throws {
        let txID = generateTransactionID()
        let msg = DHTMessage.query(
            transactionID: txID,
            queryType: .getPeers,
            arguments: [
                (key: Data("id".utf8), value: .string(nodeID.bytes)),
                (key: Data("info_hash".utf8), value: .string(infoHash.bytes)),
            ]
        )
        try await sendMessage(msg, to: address, port: port)
    }

    /// Send a get_peers query and wait for a response with peers/nodes.
    public func getPeersAndWait(infoHash: InfoHash, to address: String, port: UInt16) async throws -> DHTMessage {
        let txID = generateTransactionID()
        let msg = DHTMessage.query(
            transactionID: txID,
            queryType: .getPeers,
            arguments: [
                (key: Data("id".utf8), value: .string(nodeID.bytes)),
                (key: Data("info_hash".utf8), value: .string(infoHash.bytes)),
            ]
        )
        return try await sendAndWait(msg, to: address, port: port)
    }

    /// Send an announce_peer query.
    public func announcePeer(infoHash: InfoHash, port: UInt16, token: Data,
                              to address: String, nodePort: UInt16) async throws {
        let txID = generateTransactionID()
        let msg = DHTMessage.query(
            transactionID: txID,
            queryType: .announcePeer,
            arguments: [
                (key: Data("id".utf8), value: .string(nodeID.bytes)),
                (key: Data("implied_port".utf8), value: .integer(0)),
                (key: Data("info_hash".utf8), value: .string(infoHash.bytes)),
                (key: Data("port".utf8), value: .integer(Int64(port))),
                (key: Data("token".utf8), value: .string(token)),
            ]
        )
        try await sendMessage(msg, to: address, port: nodePort)
    }

    /// Get closest nodes from routing table.
    public func closestNodes(to target: NodeID) -> [DHTNodeEntry] {
        routingTable.closestNodes(to: target)
    }

    /// Add a node to the routing table.
    public func addNode(_ entry: DHTNodeEntry) {
        _ = routingTable.insert(entry)
    }

    /// Number of nodes in routing table.
    public func nodeCount() -> Int {
        routingTable.nodeCount
    }

    // MARK: - Private

    private func generateTransactionID() -> Data {
        var data = Data(count: 2)
        data[0] = UInt8.random(in: 0...255)
        data[1] = UInt8.random(in: 0...255)
        return data
    }

    private func sendMessage(_ msg: DHTMessage, to address: String, port: UInt16) async throws {
        guard socketFD >= 0 else { return }
        let data = msg.encode()

        var destAddr = sockaddr_in()
        destAddr.sin_family = sa_family_t(AF_INET)
        destAddr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, address, &destAddr.sin_addr) == 1 else { return }

        _ = data.withUnsafeBytes { rawBuffer in
            withUnsafePointer(to: &destAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    sendto(socketFD, rawBuffer.baseAddress, data.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    /// Parse compact node info (26 bytes each: 20 ID + 4 IP + 2 port).
    private func parseCompactNodes(_ data: Data) {
        var offset = 0
        while offset + 26 <= data.count {
            let id = NodeID(bytes: Data(data[data.startIndex + offset..<data.startIndex + offset + 20]))
            let ip = "\(data[data.startIndex + offset + 20]).\(data[data.startIndex + offset + 21]).\(data[data.startIndex + offset + 22]).\(data[data.startIndex + offset + 23])"
            let port = UInt16(data[data.startIndex + offset + 24]) << 8 | UInt16(data[data.startIndex + offset + 25])
            let entry = DHTNodeEntry(id: id, address: ip, port: port)
            _ = routingTable.insert(entry)
            offset += 26
        }
    }

    /// Encode nodes to compact format.
    private func encodeCompactNodes(_ nodes: [DHTNodeEntry]) -> Data {
        var data = Data()
        for node in nodes {
            data.append(node.id.bytes)
            let parts = node.address.split(separator: ".")
            for part in parts {
                data.append(UInt8(part) ?? 0)
            }
            data.append(contentsOf: node.port.bigEndianBytes)
        }
        return data
    }

    private func resolveHostname(_ hostname: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            Task.detached(priority: .userInitiated) {
                var hints = addrinfo()
                hints.ai_family = AF_INET
                hints.ai_socktype = Int32(SOCK_DGRAM)
                var result: UnsafeMutablePointer<addrinfo>?
                let status = getaddrinfo(hostname, nil, &hints, &result)
                guard status == 0, let addrInfo = result else {
                    continuation.resume(throwing: DHTMessageError.invalidMessage)
                    return
                }
                defer { freeaddrinfo(result) }
                guard let addr = addrInfo.pointee.ai_addr else {
                    continuation.resume(throwing: DHTMessageError.invalidMessage)
                    return
                }
                var hostBuf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(addr, addrInfo.pointee.ai_addrlen, &hostBuf, socklen_t(NI_MAXHOST), nil, 0, NI_NUMERICHOST)
                let host = hostBuf.withUnsafeBufferPointer { ptr in
                    ptr.baseAddress.map { String(cString: $0) } ?? ""
                }
                continuation.resume(returning: host)
            }
        }
    }
}
