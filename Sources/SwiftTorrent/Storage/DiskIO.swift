import Foundation
import NIOCore
import NIOPosix

public enum DiskIOError: Error {
    case pathTraversalDetected(String)
}

/// Async disk I/O using NIO thread pool to avoid blocking Swift cooperative threads.
public actor DiskIO {
    private let basePath: String
    private let fileStorage: FileStorage
    private let threadPool: NIOThreadPool
    public let usePartExtension: Bool

    public init(basePath: String, fileStorage: FileStorage, threadPoolSize: Int = 4, usePartExtension: Bool = true) {
        self.basePath = basePath
        self.fileStorage = fileStorage
        self.threadPool = NIOThreadPool(numberOfThreads: threadPoolSize)
        self.usePartExtension = usePartExtension
        self.threadPool.start()
    }

    deinit {
        try? threadPool.syncShutdownGracefully()
    }

    /// Explicitly shutdown thread pool.
    public func shutdown() async {
        await withCheckedContinuation { continuation in
            threadPool.shutdownGracefully { _ in
                continuation.resume()
            }
        }
    }

    private func resolvedPath(for slicePath: String) throws -> String {
        let baseStandardized = URL(fileURLWithPath: basePath).standardizedFileURL.path
        let combined = (basePath as NSString).appendingPathComponent(slicePath)
        let resolvedStandardized = URL(fileURLWithPath: combined).standardizedFileURL.path
        guard resolvedStandardized.hasPrefix(baseStandardized) else {
            throw DiskIOError.pathTraversalDetected(slicePath)
        }
        return resolvedStandardized
    }

    /// Target path on disk for writing: uses .part if enabled and final file is not complete.
    private nonisolated static func effectiveWritePath(for resolvedPath: String, usePartExtension: Bool) -> String {
        guard usePartExtension else { return resolvedPath }
        if FileManager.default.fileExists(atPath: resolvedPath) {
            return resolvedPath
        }
        return resolvedPath + ".part"
    }

    /// Source path on disk for reading: prefers final file, then .part file.
    private nonisolated static func effectiveReadPath(for resolvedPath: String, usePartExtension: Bool) -> String {
        if FileManager.default.fileExists(atPath: resolvedPath) {
            return resolvedPath
        }
        if usePartExtension {
            let partPath = resolvedPath + ".part"
            if FileManager.default.fileExists(atPath: partPath) {
                return partPath
            }
        }
        return resolvedPath
    }

    /// Write a piece to disk.
    public func writePiece(index: Int, data: Data) async throws {
        let slices = fileStorage.fileSlices(forPiece: index)
        var resolvedSlicesList: [(path: String, offset: Int64, length: Int)] = []
        for slice in slices {
            let path = try resolvedPath(for: slice.path)
            resolvedSlicesList.append((path: path, offset: slice.offset, length: slice.length))
        }
        let resolvedSlices = resolvedSlicesList

        let usePart = self.usePartExtension
        try await threadPool.runIfActive {
            var dataOffset = 0
            for slice in resolvedSlices {
                let finalPath = slice.path
                let filePath = Self.effectiveWritePath(for: finalPath, usePartExtension: usePart)
                let dir = (filePath as NSString).deletingLastPathComponent
                try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

                if !FileManager.default.fileExists(atPath: filePath) {
                    FileManager.default.createFile(atPath: filePath, contents: nil)
                }

                let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: filePath))
                defer { try? handle.close() }
                try handle.seek(toOffset: UInt64(slice.offset))
                let chunk = data.subdata(in: dataOffset..<dataOffset + slice.length)
                try handle.write(contentsOf: chunk)
                dataOffset += slice.length
            }
        }
    }

    /// Read a piece from disk.
    public func readPiece(index: Int) async throws -> Data {
        let slices = fileStorage.fileSlices(forPiece: index)
        var resolvedSlicesList: [(path: String, offset: Int64, length: Int)] = []
        for slice in slices {
            let path = try resolvedPath(for: slice.path)
            resolvedSlicesList.append((path: path, offset: slice.offset, length: slice.length))
        }
        let resolvedSlices = resolvedSlicesList

        let usePart = self.usePartExtension
        return try await threadPool.runIfActive {
            var result = Data()
            for slice in resolvedSlices {
                let filePath = Self.effectiveReadPath(for: slice.path, usePartExtension: usePart)
                guard FileManager.default.fileExists(atPath: filePath) else {
                    return Data()
                }
                let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: filePath))
                defer { try? handle.close() }
                try handle.seek(toOffset: UInt64(slice.offset))
                guard let chunk = try handle.read(upToCount: slice.length), chunk.count == slice.length else {
                    return Data()
                }
                result.append(chunk)
            }
            return result
        }
    }

    /// Read a specific block (slice) of a piece from disk.
    public func readBlock(pieceIndex: Int, offset: Int, length: Int) async throws -> Data {
        let pieceData = try await readPiece(index: pieceIndex)
        guard offset < pieceData.count else { return Data() }
        let end = min(offset + length, pieceData.count)
        return pieceData.subdata(in: offset..<end)
    }

    /// Ensure all files exist with correct sizes (creates .part file if enabled).
    public func allocateFiles() async throws {
        var resolvedFilesList: [(path: String, length: Int64)] = []
        for file in fileStorage.files {
            let path = try resolvedPath(for: file.path)
            resolvedFilesList.append((path: path, length: file.length))
        }
        let resolvedFiles = resolvedFilesList

        let usePart = self.usePartExtension
        try await threadPool.runIfActive {
            for file in resolvedFiles {
                let finalPath = file.path
                let dir = (finalPath as NSString).deletingLastPathComponent
                try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

                // If finished file already exists, don't allocate .part
                if FileManager.default.fileExists(atPath: finalPath) {
                    continue
                }

                let targetPath = usePart ? (finalPath + ".part") : finalPath
                if !FileManager.default.fileExists(atPath: targetPath) {
                    FileManager.default.createFile(atPath: targetPath, contents: nil)
                }
            }
        }
    }

    /// Finalize all completed files by renaming any .part files to their final names.
    public func finalizeFiles() async throws {
        guard usePartExtension else { return }
        var resolvedFilesList: [String] = []
        for file in fileStorage.files {
            let path = try resolvedPath(for: file.path)
            resolvedFilesList.append(path)
        }
        let resolvedFiles = resolvedFilesList

        try await threadPool.runIfActive {
            for finalPath in resolvedFiles {
                let partPath = finalPath + ".part"
                if FileManager.default.fileExists(atPath: partPath) {
                    if FileManager.default.fileExists(atPath: finalPath) {
                        try? FileManager.default.removeItem(atPath: finalPath)
                    }
                    try FileManager.default.moveItem(atPath: partPath, toPath: finalPath)
                }
            }
        }
    }

    /// Check whether any of the torrent's files (or their .part counterparts) already exist on disk.
    public func hasExistingFiles() async -> Bool {
        var paths: [String] = []
        for file in fileStorage.files {
            if let path = try? resolvedPath(for: file.path) {
                paths.append(path)
            }
        }
        let resolvedPaths = paths
        let usePart = self.usePartExtension
        return (try? await threadPool.runIfActive {
            for path in resolvedPaths {
                if FileManager.default.fileExists(atPath: path) {
                    return true
                }
                if usePart && FileManager.default.fileExists(atPath: path + ".part") {
                    return true
                }
            }
            return false
        }) ?? false
    }
}
