import Foundation
import Crypto

/// Represents a parsed .torrent file.
public struct TorrentInfo: Sendable, Identifiable, Equatable, Hashable {
    public var id: InfoHash { infoHash }
    public let infoHash: InfoHash
    public let name: String
    public let pieceLength: Int
    public let pieces: Data  // concatenated SHA-1 hashes, 20 bytes each
    public let totalSize: Int64
    public let files: [FileEntry]
    public let isPrivate: Bool
    public let comment: String?
    public let createdBy: String?
    public let creationDate: Date?
    public let announceURL: String?
    public let announceList: [[String]]

    /// A single file within the torrent.
    public struct FileEntry: Sendable, Identifiable, Equatable, Hashable {
        public var id: String { path }
        public let path: String
        public let length: Int64
        public let offset: Int64  // byte offset within the torrent data

        public init(path: String, length: Int64, offset: Int64) {
            self.path = path
            self.length = length
            self.offset = offset
        }
    }

    public init(
        infoHash: InfoHash,
        name: String,
        pieceLength: Int,
        pieces: Data,
        totalSize: Int64,
        files: [FileEntry],
        isPrivate: Bool,
        comment: String?,
        createdBy: String?,
        creationDate: Date?,
        announceURL: String?,
        announceList: [[String]]
    ) {
        self.infoHash = infoHash
        self.name = name
        self.pieceLength = pieceLength
        self.pieces = pieces
        self.totalSize = totalSize
        self.files = files
        self.isPrivate = isPrivate
        self.comment = comment
        self.createdBy = createdBy
        self.creationDate = creationDate
        self.announceURL = announceURL
        self.announceList = announceList
    }

    public var pieceCount: Int {
        pieces.count / 20
    }

    /// Parse a .torrent file from raw data.
    public static func parse(from data: Data) throws -> TorrentInfo {
        let decoder = BencodeDecoder()
        let root = try decoder.decode(data)

        guard case .dictionary = root else {
            throw TorrentInfoError.invalidFormat("Root is not a dictionary")
        }
        guard let infoValue = root["info"],
              case .dictionary = infoValue else {
            throw TorrentInfoError.invalidFormat("Missing 'info' dictionary")
        }

        // Find the raw bytes of the info dictionary for hashing
        let infoData = try findInfoDictBytes(in: data)
        let infoHash = InfoHash.v1(from: infoData)

        guard let nameValue = infoValue["name"], let rawName = nameValue.utf8String else {
            throw TorrentInfoError.invalidFormat("Missing 'name'")
        }
        let safeName = sanitizePathComponent(rawName)
        guard !safeName.isEmpty else {
            throw TorrentInfoError.invalidFormat("Invalid 'name' component")
        }

        guard let plValue = infoValue["piece length"], let pieceLength = plValue.integerValue else {
            throw TorrentInfoError.invalidFormat("Missing 'piece length'")
        }
        guard let piecesValue = infoValue["pieces"], let pieces = piecesValue.stringValue else {
            throw TorrentInfoError.invalidFormat("Missing 'pieces'")
        }

        let isPrivate = infoValue["private"]?.integerValue == 1

        // Parse files
        var files: [FileEntry] = []
        var totalSize: Int64 = 0

        if let filesValue = infoValue["files"]?.listValue {
            // Multi-file torrent
            for fileValue in filesValue {
                guard let length = fileValue["length"]?.integerValue,
                      let pathList = fileValue["path"]?.listValue else {
                    throw TorrentInfoError.invalidFormat("Invalid file entry")
                }
                let rawComponents = pathList.compactMap { $0.utf8String }
                let safeComponents = rawComponents.compactMap { comp -> String? in
                    let sanitized = sanitizePathComponent(comp)
                    return sanitized.isEmpty ? nil : sanitized
                }
                guard !safeComponents.isEmpty else {
                    throw TorrentInfoError.invalidFormat("Invalid or unsafe file path")
                }
                let path = ([safeName] + safeComponents).joined(separator: "/")
                files.append(FileEntry(path: path, length: length, offset: totalSize))
                totalSize += length
            }
        } else if let length = infoValue["length"]?.integerValue {
            // Single-file torrent
            files.append(FileEntry(path: safeName, length: length, offset: 0))
            totalSize = length
        } else {
            throw TorrentInfoError.invalidFormat("Missing 'length' or 'files'")
        }

        let comment = root["comment"]?.utf8String
        let createdBy = root["created by"]?.utf8String
        let creationDate: Date? = root["creation date"]?.integerValue.map {
            Date(timeIntervalSince1970: TimeInterval($0))
        }
        let announceURL = root["announce"]?.utf8String
        var announceList: [[String]] = []
        if let al = root["announce-list"]?.listValue {
            for tier in al {
                if let urls = tier.listValue {
                    announceList.append(urls.compactMap { $0.utf8String })
                }
            }
        }

        return TorrentInfo(
            infoHash: infoHash, name: safeName, pieceLength: Int(pieceLength),
            pieces: pieces, totalSize: totalSize, files: files,
            isPrivate: isPrivate, comment: comment, createdBy: createdBy,
            creationDate: creationDate, announceURL: announceURL,
            announceList: announceList
        )
    }

    /// Sanitize single path component preventing directory traversal attacks.
    public static func sanitizePathComponent(_ component: String) -> String {
        var comp = component.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while comp.contains("..") {
            comp = comp.replacingOccurrences(of: "..", with: "_")
        }
        if comp == "." { return "_" }
        return comp
    }

    /// Extract raw bytes of the "info" dictionary value from bencoded data.
    private static func findInfoDictBytes(in data: Data) throws -> Data {
        // Find top-level info key by walking top-level dictionary
        let decoder = BencodeDecoder()
        var index = data.startIndex
        guard index < data.endIndex, data[index] == UInt8(ascii: "d") else {
            throw TorrentInfoError.invalidFormat("Root is not a dictionary")
        }
        index = data.index(after: index) // skip 'd'

        while index < data.endIndex && data[index] != UInt8(ascii: "e") {
            let keyStart = index
            let keyValue = try decoder.decodeWithRange(Data(data[keyStart...])).value
            guard case .string(let keyData) = keyValue else {
                throw TorrentInfoError.invalidFormat("Invalid dictionary key")
            }
            // Advance index past the key string bencode representation
            let colonIdx = data[index...].firstIndex(of: UInt8(ascii: ":"))!
            let keyLen = keyData.count
            index = data.index(colonIdx, offsetBy: 1 + keyLen)

            let valueStart = index
            if keyData == Data("info".utf8) {
                var valIndex = valueStart
                try skipBencodeValue(data, index: &valIndex)
                return Data(data[valueStart..<valIndex])
            } else {
                try skipBencodeValue(data, index: &index)
            }
        }

        throw TorrentInfoError.invalidFormat("Cannot find info key")
    }

    private static func skipBencodeValue(_ data: Data, index: inout Data.Index) throws {
        guard index < data.endIndex else { throw BencodeError.unexpectedEnd }
        switch data[index] {
        case UInt8(ascii: "i"):
            guard let end = data[index...].firstIndex(of: UInt8(ascii: "e")) else {
                throw BencodeError.unexpectedEnd
            }
            index = data.index(after: end)
        case UInt8(ascii: "l"), UInt8(ascii: "d"):
            index = data.index(after: index)
            while index < data.endIndex && data[index] != UInt8(ascii: "e") {
                try skipBencodeValue(data, index: &index)
            }
            guard index < data.endIndex else { throw BencodeError.unexpectedEnd }
            index = data.index(after: index)
        case UInt8(ascii: "0")...UInt8(ascii: "9"):
            guard let colon = data[index...].firstIndex(of: UInt8(ascii: ":")) else {
                throw BencodeError.unexpectedEnd
            }
            guard let lenStr = String(data: data[index..<colon], encoding: .ascii),
                  let len = Int(lenStr) else {
                throw BencodeError.invalidStringLength
            }
            index = data.index(colon, offsetBy: 1 + len)
        default:
            throw BencodeError.invalidFormat("Unexpected byte in skip")
        }
    }
}

public enum TorrentInfoError: Error, Equatable {
    case invalidFormat(String)
}
