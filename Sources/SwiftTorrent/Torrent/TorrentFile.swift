import Foundation
import Crypto

/// Utility for creating .torrent files.
public struct TorrentFile: Sendable {

    /// Create a .torrent file from a directory or single file.
    public static func create(
        path: String,
        announceURL: String,
        pieceLength: Int = 256 * 1024,
        comment: String? = nil,
        isPrivate: Bool = false
    ) throws -> Data {
        let fileManager = FileManager.default
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDir) else {
            throw TorrentFileError.fileNotFound(path)
        }

        let cleanPath = (path as NSString).standardizingPath
        let name = (cleanPath as NSString).lastPathComponent
        var infoPairs: [(key: Data, value: BencodeValue)] = []

        if isDir.boolValue {
            // Multi-file torrent
            let files = try enumerateFiles(at: cleanPath)
            var fileEntries: [BencodeValue] = []
            for file in files {
                let prefixLen = cleanPath.hasSuffix("/") ? cleanPath.count : cleanPath.count + 1
                let relativePath = String(file.path.dropFirst(prefixLen))
                let components = relativePath.split(separator: "/").map { String($0) }
                let pathList = components.map { BencodeValue.string(Data($0.utf8)) }
                let fileDict: BencodeValue = .dictionary([
                    (key: Data("length".utf8), value: .integer(file.size)),
                    (key: Data("path".utf8), value: .list(pathList))
                ])
                fileEntries.append(fileDict)
            }
            infoPairs.append((key: Data("files".utf8), value: .list(fileEntries)))
        } else {
            // Single-file torrent
            let attrs = try fileManager.attributesOfItem(atPath: cleanPath)
            let size = ((attrs[.size] as? NSNumber)?.int64Value) ?? 0
            infoPairs.append((key: Data("length".utf8), value: .integer(size)))
        }

        infoPairs.append((key: Data("name".utf8), value: .string(Data(name.utf8))))
        infoPairs.append((key: Data("piece length".utf8), value: .integer(Int64(pieceLength))))

        // Compute pieces hashes in a memory-safe streaming fashion
        let piecesData = try computePieces(path: cleanPath, isDir: isDir.boolValue, pieceLength: pieceLength)
        infoPairs.append((key: Data("pieces".utf8), value: .string(piecesData)))

        if isPrivate {
            infoPairs.append((key: Data("private".utf8), value: .integer(1)))
        }

        let infoDict: BencodeValue = .dictionary(infoPairs)

        var rootPairs: [(key: Data, value: BencodeValue)] = [
            (key: Data("announce".utf8), value: .string(Data(announceURL.utf8))),
            (key: Data("info".utf8), value: infoDict)
        ]
        if let comment = comment {
            rootPairs.append((key: Data("comment".utf8), value: .string(Data(comment.utf8))))
        }
        rootPairs.append((key: Data("created by".utf8), value: .string(Data("SwiftTorrent".utf8))))
        rootPairs.append((key: Data("creation date".utf8), value: .integer(Int64(Date().timeIntervalSince1970))))

        let root: BencodeValue = .dictionary(rootPairs)
        return BencodeEncoder().encode(root)
    }

    private struct FileInfo {
        let path: String
        let size: Int64
    }

    private static func enumerateFiles(at dirPath: String) throws -> [FileInfo] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: dirPath) else {
            throw TorrentFileError.fileNotFound(dirPath)
        }
        var files: [FileInfo] = []
        while let relativePath = enumerator.nextObject() as? String {
            let fullPath = (dirPath as NSString).appendingPathComponent(relativePath)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: fullPath, isDirectory: &isDir), !isDir.boolValue {
                let attrs = try fm.attributesOfItem(atPath: fullPath)
                let size = ((attrs[.size] as? NSNumber)?.int64Value) ?? 0
                files.append(FileInfo(path: fullPath, size: size))
            }
        }
        return files.sorted { $0.path < $1.path }
    }

    private static func computePieces(path: String, isDir: Bool, pieceLength: Int) throws -> Data {
        let filePaths: [String]
        if isDir {
            let files = try enumerateFiles(at: path)
            filePaths = files.map(\.path)
        } else {
            filePaths = [path]
        }

        var pieces = Data()
        var currentPieceBuffer = Data()
        currentPieceBuffer.reserveCapacity(pieceLength)

        for filePath in filePaths {
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: filePath))
            defer { try? handle.close() }

            while true {
                let needed = pieceLength - currentPieceBuffer.count
                let chunk = handle.readData(ofLength: needed)
                if chunk.isEmpty { break }
                currentPieceBuffer.append(chunk)

                if currentPieceBuffer.count == pieceLength {
                    let hash = Insecure.SHA1.hash(data: currentPieceBuffer)
                    pieces.append(contentsOf: hash)
                    currentPieceBuffer.removeAll(keepingCapacity: true)
                }
            }
        }

        if !currentPieceBuffer.isEmpty {
            let hash = Insecure.SHA1.hash(data: currentPieceBuffer)
            pieces.append(contentsOf: hash)
        }

        return pieces
    }
}

public enum TorrentFileError: Error {
    case fileNotFound(String)
}
