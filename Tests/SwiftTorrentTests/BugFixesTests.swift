import XCTest
import Foundation
import CryptoKit
@testable import SwiftTorrent

final class BugFixesTests: XCTestCase {

    func testOutOfOrderBlocksInPieceManager() async {
        // 32KB piece: 2 blocks of 16KB
        let data = Data(repeating: 0x42, count: 32768)
        let hash = Data(Insecure.SHA1.hash(data: data))
        let info = makeTorrentInfo(pieceLength: 32768, totalSize: 32768, pieceHashes: hash)
        let pm = PieceManager(info: info)

        await pm.startPiece(0)

        // Block 1 (offset 16384) arrives BEFORE Block 0 (offset 0)
        let block1 = Data(repeating: 0x42, count: 16384)
        await pm.addBlock(pieceIndex: 0, offset: 16384, data: block1)

        let isBlock0Recv = await pm.isBlockReceived(pieceIndex: 0, offset: 0)
        let isBlock1Recv = await pm.isBlockReceived(pieceIndex: 0, offset: 16384)
        XCTAssertFalse(isBlock0Recv, "Block 0 should not be marked as received")
        XCTAssertTrue(isBlock1Recv, "Block 1 should be marked as received")

        let allReceivedBefore = await pm.areAllBlocksReceived(0)
        XCTAssertFalse(allReceivedBefore, "Piece must not be considered fully received when only block 1 arrived")

        let prematureComplete = await pm.completePiece(0)
        XCTAssertFalse(prematureComplete, "Piece completion must fail when blocks are missing")

        // Now block 0 arrives
        let block0 = Data(repeating: 0x42, count: 16384)
        await pm.addBlock(pieceIndex: 0, offset: 0, data: block0)

        let allReceivedAfter = await pm.areAllBlocksReceived(0)
        XCTAssertTrue(allReceivedAfter, "All blocks should now be received")

        let verified = await pm.completePiece(0)
        XCTAssertTrue(verified, "Piece verification must succeed once all blocks are present")
    }

    func testPathTraversalSanitization() {
        XCTAssertEqual(TorrentInfo.sanitizePathComponent("../../etc/passwd"), "____etc_passwd")
        XCTAssertEqual(TorrentInfo.sanitizePathComponent(".."), "_")
        XCTAssertEqual(TorrentInfo.sanitizePathComponent("."), "_")
        XCTAssertEqual(TorrentInfo.sanitizePathComponent("/root/secret.txt"), "_root_secret.txt")
        XCTAssertEqual(TorrentInfo.sanitizePathComponent("normal_file.mp4"), "normal_file.mp4")
    }

    func testSessionRemoveTorrentDoesNotDeleteSavePath() async {
        let tempDir = NSTemporaryDirectory() + "safe_session_test_\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        // Create dummy file inside savePath that does NOT belong to torrent
        let userFile = (tempDir as NSString).appendingPathComponent("important_user_doc.txt")
        FileManager.default.createFile(atPath: userFile, contents: Data("keep me safe".utf8))

        let settings = SessionSettings(listenPort: 0, dhtEnabled: false, savePath: tempDir)
        let session = Session(settings: settings)

        let dummyHash = InfoHash(bytes: Data(repeating: 0x11, count: 20))
        let info = makeTorrentInfo(pieceLength: 16384, totalSize: 16384)
        let params = AddTorrentParams(torrentInfo: info, savePath: tempDir, paused: true)

        let handle = try! await session.addTorrent(params)
        XCTAssertNotNil(handle)

        // Remove torrent with deleteFiles: true
        await session.removeTorrent(dummyHash, deleteFiles: true)

        // The savePath directory AND the user's unrelated file MUST still exist!
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir), "Session savePath must NOT be deleted")
        XCTAssertTrue(FileManager.default.fileExists(atPath: userFile), "Unrelated user file in savePath must NOT be deleted")
    }

    func testDiskIOPathTraversalDetection() async {
        let tempDir = NSTemporaryDirectory() + "diskio_safe_test_\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let maliciousFile = TorrentInfo.FileEntry(path: "../../../escaped.bin", length: 64, offset: 0)
        let fs = FileStorage(files: [maliciousFile], pieceLength: 64, totalSize: 64)
        let dio = DiskIO(basePath: tempDir, fileStorage: fs)

        do {
            try await dio.allocateFiles()
            XCTFail("allocateFiles should have thrown pathTraversalDetected")
        } catch {
            // Expected
            XCTAssertTrue(error is DiskIOError)
        }
    }
}
