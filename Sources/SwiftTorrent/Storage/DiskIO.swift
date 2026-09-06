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

    public init(basePath: String, fileStorage: FileStorage, threadPoolSize: Int = 4) {
        self.basePath = basePath
        self.fileStorage = fileStorage
        self.threadPool = NIOThreadPool(numberOfThreads: threadPoolSize)
        self.threadPool.start()
    }

    deinit {
        try? threadPool.syncShutdownGracefully()
    }

    /// Explicitly shutdown thread pool.
    public func shutdown() async {
        try? threadPool.syncShutdownGracefully()
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

    /// Write a piece to disk.
    public func writePiece(index: Int, data: Data) async throws {
        let slices = fileStorage.fileSlices(forPiece: index)
        var resolvedSlices: [(path: String, offset: Int64, length: Int)] = []
        for slice in slices {
            let path = try resolvedPath(for: slice.path)
            resolvedSlices.append((path: path, offset: slice.offset, length: slice.length))
        }

        try await threadPool.runIfActive {
            var dataOffset = 0
            for slice in resolvedSlices {
                let filePath = slice.path
                let dir = (filePath as NSString).deletingLastPathComponent
                try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

                if !FileManager.default.fileExists(atPath: filePath) {
                    FileManager.default.createFile(atPath: filePath, contents: nil)
                }

                let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: filePath))
                defer { try? handle.close() }
                try handle.seek(toOffset: UInt64(slice.offset))
                let chunk = data.subdata(in: dataOffset..<dataOffset + slice.length)
                handle.write(chunk)
                dataOffset += slice.length
            }
        }
    }

    /// Read a piece from disk.
    public func readPiece(index: Int) async throws -> Data {
        let slices = fileStorage.fileSlices(forPiece: index)
        var resolvedSlices: [(path: String, offset: Int64, length: Int)] = []
        for slice in slices {
            let path = try resolvedPath(for: slice.path)
            resolvedSlices.append((path: path, offset: slice.offset, length: slice.length))
        }

        return try await threadPool.runIfActive {
            var result = Data()
            for slice in resolvedSlices {
                let filePath = slice.path
                let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: filePath))
                defer { try? handle.close() }
                try handle.seek(toOffset: UInt64(slice.offset))
                let chunk = handle.readData(ofLength: slice.length)
                result.append(chunk)
            }
            return result
        }
    }

    /// Ensure all files exist with correct sizes.
    public func allocateFiles() async throws {
        var resolvedFiles: [(path: String, length: Int64)] = []
        for file in fileStorage.files {
            let path = try resolvedPath(for: file.path)
            resolvedFiles.append((path: path, length: file.length))
        }

        try await threadPool.runIfActive {
            for file in resolvedFiles {
                let filePath = file.path
                let dir = (filePath as NSString).deletingLastPathComponent
                try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

                if !FileManager.default.fileExists(atPath: filePath) {
                    FileManager.default.createFile(atPath: filePath, contents: nil)
                    let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: filePath))
                    try handle.truncate(atOffset: UInt64(file.length))
                    try handle.close()
                }
            }
        }
    }
}
