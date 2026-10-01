import Foundation
import Testing
import ZIPFoundation
@testable import ZipMello

private final class Workspace: Sendable {
    let root: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    func file(_ name: String) -> URL { root.appending(path: name) }
}

@Suite
struct ArchiveTests {
    @Test(arguments: [ArchiveCompression.stored, .deflate])
    func roundTrip(compression: ArchiveCompression) async throws {
        let work = try Workspace()
        let data = Data(repeating: 97, count: 200_000)
        try data.write(to: work.file("source"))
        try await ArchiveWriter().create(at: work.file("chapter.cbz"), assets: [
            .init(path: "001.png", content: .file(work.file("source")), compression: compression),
            .init(path: "ComicInfo.xml", content: .bytes(Data("<ComicInfo/>".utf8)), compression: compression),
            .init(path: "日本語/説明.md", content: .bytes(Data("説明".utf8)), compression: compression)
        ])
        let reader = try await ArchiveReader.open(work.file("chapter.cbz"))
        #expect(try await reader.listing().map(\.path) == ["001.png", "ComicInfo.xml", "日本語/説明.md"])
        #expect(try await reader.read("001.png") == data)
        #expect(try await reader.read("日本語/説明.md") == Data("説明".utf8))
        try await reader.extract("001.png", to: work.file("extracted"))
        #expect(try Data(contentsOf: work.file("extracted")) == data)
        await reader.close()
        await #expect(throws: ArchiveFailure.closed) { try await reader.listing() }
    }

    @Test(arguments: ["../escape", "/absolute", "a/../b", "a\\b", "a//b", "C:/escape", "./page", ""])
    func rejectsUnsafePaths(path: String) async throws {
        let work = try Workspace()
        await #expect(throws: ArchiveFailure.unsafePath(path)) {
            try await ArchiveWriter().create(at: work.file("bad.zip"), assets: [.init(path: path, content: .bytes(Data()))])
        }
        #expect(!FileManager.default.fileExists(atPath: work.file("bad.zip").path))
    }

    @Test
    func rejectsUntrustedTraversalOnOpen() async throws {
        let work = try Workspace()
        do {
            let archive = try Archive(url: work.file("bad.zip"), accessMode: .create)
            try archive.addEntry(with: "../escape", type: .file, uncompressedSize: Int64(1)) { _, _ in Data([1]) }
        }
        await #expect(throws: ArchiveFailure.unsafePath("../escape")) { try await ArchiveReader.open(work.file("bad.zip")) }
    }

    @Test
    func rejectsSymlinksOnOpen() async throws {
        let work = try Workspace()
        do {
            let archive = try Archive(url: work.file("link.zip"), accessMode: .create)
            let target = Data("../escape".utf8)
            try archive.addEntry(with: "link", type: .symlink, uncompressedSize: Int64(target.count)) { _, _ in target }
        }
        await #expect(throws: ArchiveFailure.unsupportedEntry("link")) { try await ArchiveReader.open(work.file("link.zip")) }
    }

    @Test
    func budgetsApplyToReaderAndWriter() async throws {
        let work = try Workspace()
        let assets = [ArchiveAsset(path: "one", content: .bytes(Data(repeating: 1, count: 20))),
                      ArchiveAsset(path: "two", content: .bytes(Data(repeating: 2, count: 20)))]
        try await ArchiveWriter().create(at: work.file("valid.zip"), assets: assets)
        await #expect(throws: ArchiveFailure.memberTooLarge("one")) {
            try await ArchiveReader.open(work.file("valid.zip"), limits: .init(maximumEntryBytes: 10))
        }
        await #expect(throws: ArchiveFailure.expandedArchiveTooLarge) {
            try await ArchiveReader.open(work.file("valid.zip"), limits: .init(maximumExpandedBytes: 30))
        }
        await #expect(throws: ArchiveFailure.tooManyEntries) {
            try await ArchiveReader.open(work.file("valid.zip"), limits: .init(maximumEntries: 1))
        }
        await #expect(throws: ArchiveFailure.archiveTooLarge) {
            try await ArchiveReader.open(work.file("valid.zip"), limits: .init(maximumArchiveBytes: 1))
        }
        await #expect(throws: ArchiveFailure.archiveTooLarge) {
            try await ArchiveWriter().create(at: work.file("too-large.zip"), assets: assets, limits: .init(maximumArchiveBytes: 1))
        }
        #expect(!FileManager.default.fileExists(atPath: work.file("too-large.zip").path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: work.root.path) == ["valid.zip"])
    }

    @Test
    func checksumFailureDoesNotPublishFile() async throws {
        let work = try Workspace()
        let payload = Data("unique-payload-for-crc-check".utf8)
        try await ArchiveWriter().create(at: work.file("corrupt.zip"), assets: [.init(path: "page", content: .bytes(payload))])
        var bytes = try Data(contentsOf: work.file("corrupt.zip"))
        let range = try #require(bytes.range(of: payload))
        bytes[range.lowerBound] ^= 1
        try bytes.write(to: work.file("corrupt.zip"))
        let reader = try await ArchiveReader.open(work.file("corrupt.zip"))
        await #expect(throws: ArchiveFailure.checksumMismatch("page")) {
            try await reader.extract("page", to: work.file("output"))
        }
        #expect(!FileManager.default.fileExists(atPath: work.file("output").path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: work.root.path) == ["corrupt.zip"])
    }

    @Test
    func duplicateAndMissingEntries() async throws {
        let work = try Workspace()
        let asset = ArchiveAsset(path: "page", content: .bytes(Data()))
        await #expect(throws: ArchiveFailure.duplicatePath("page")) {
            try await ArchiveWriter().create(at: work.file("bad.zip"), assets: [asset, asset])
        }
        do {
            let archive = try Archive(url: work.file("duplicate.zip"), accessMode: .create)
            for _ in 0..<2 { try archive.addEntry(with: "page", type: .file, uncompressedSize: Int64(0)) { _, _ in Data() } }
        }
        await #expect(throws: ArchiveFailure.duplicatePath("page")) { try await ArchiveReader.open(work.file("duplicate.zip")) }
        try await ArchiveWriter().create(at: work.file("valid.zip"), assets: [asset])
        let reader = try await ArchiveReader.open(work.file("valid.zip"))
        await #expect(throws: ArchiveFailure.missingEntry("absent")) { try await reader.read("absent") }
    }

    @Test
    func preservesExistingDestination() async throws {
        let work = try Workspace()
        let original = Data("keep".utf8)
        try original.write(to: work.file("existing"))
        await #expect(throws: ArchiveFailure.destinationExists) {
            try await ArchiveWriter().create(at: work.file("existing"), assets: [])
        }
        #expect(try Data(contentsOf: work.file("existing")) == original)
    }

    @Test
    func cancelledTaskDoesNotCreateArchive() async throws {
        let work = try Workspace()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await ArchiveWriter().create(at: work.file("cancelled.zip"), assets: [])
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: work.file("cancelled.zip").path))
    }

    @Test
    func concurrentReadsStayIsolated() async throws {
        let work = try Workspace()
        let first = Data(repeating: 1, count: 80_000)
        let second = Data(repeating: 2, count: 80_000)
        try await ArchiveWriter().create(at: work.file("pages.zip"), assets: [
            .init(path: "one", content: .bytes(first), compression: .deflate),
            .init(path: "two", content: .bytes(second), compression: .deflate)
        ])
        let reader = try await ArchiveReader.open(work.file("pages.zip"))
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<20 {
                group.addTask { () async throws -> Void in
                    let expected = index.isMultiple(of: 2) ? first : second
                    #expect(try await reader.read(index.isMultiple(of: 2) ? "one" : "two") == expected)
                }
            }
            try await group.waitForAll()
        }
    }
}

extension ArchiveTests {
    @Test(arguments: [1, 2, 4])
    func parallelOffsetReadsValidateEveryByte(concurrency: Int) async throws {
        let work = try Workspace()
        let assets = (0..<24).map { ArchiveAsset(path: "\($0)", content: .bytes(Data(repeating: UInt8($0), count: 160_000)), compression: .deflate) }
        try await ArchiveWriter().create(at: work.file("parallel.zip"), assets: assets)
        let reader = try await ArchiveReader.open(work.file("parallel.zip"), tuning: .init(readConcurrency: concurrency))
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<96 {
                group.addTask { () async throws -> Void in
                    #expect(try await reader.read("\(index % 24)") == Data(repeating: UInt8(index % 24), count: 160_000))
                }
            }
            try await group.waitForAll()
        }
    }

    @Test(arguments: [0, 1_024, 200_000, 4_194_304])
    func libdeflateInteroperatesWithStreaming(size: Int) async throws {
        let work = try Workspace()
        let data = Data((0..<size).map { UInt8(truncatingIfNeeded: ($0 &* 719) >> 5) })
        try await ArchiveWriter().create(at: work.file("fast.zip"), assets: [
            .init(path: "data", content: .bytes(data), compression: .deflate)
        ], tuning: .init(wholeBufferDeflateLimit: 4_194_304))
        let apple = try await ArchiveReader.open(work.file("fast.zip"))
        #expect(try await apple.read("data") == data)
        let fast = try await ArchiveReader.open(work.file("fast.zip"), tuning: .init(wholeBufferDeflateLimit: 4_194_304))
        #expect(try await fast.read("data") == data)
        try await ArchiveWriter().create(at: work.file("apple.zip"), assets: [
            .init(path: "data", content: .bytes(data), compression: .deflate)
        ])
        let cross = try await ArchiveReader.open(work.file("apple.zip"), tuning: .init(wholeBufferDeflateLimit: 4_194_304))
        #expect(try await cross.read("data") == data)
    }

    @Test
    func poolCoalescesAndInvalidatesReplacement() async throws {
        let work = try Workspace()
        let url = work.file("pooled.zip")
        try await ArchiveWriter().create(at: url, assets: [.init(path: "data", content: .bytes(Data([1])))])
        let pool = try ArchiveSessionPool(maximumSessions: 1)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<40 {
                group.addTask { () async throws -> Void in #expect(try await pool.read("data", from: url) == Data([1])) }
            }
            try await group.waitForAll()
        }
        #expect(await pool.statistics().opens == 1)
        try FileManager.default.removeItem(at: url)
        try await ArchiveWriter().create(at: url, assets: [.init(path: "data", content: .bytes(Data([2])))])
        #expect(try await pool.read("data", from: url) == Data([2]))
        #expect(await pool.statistics().opens == 2)
        await pool.removeAll()
        #expect(await pool.statistics().cachedSessions == 0)
    }

    @Test
    func poolEvictsAndRespectsIndexBudget() async throws {
        let work = try Workspace()
        for name in ["one", "two"] {
            try await ArchiveWriter().create(at: work.file(name), assets: [.init(path: "data", content: .bytes(Data([3])))])
        }
        let pool = try ArchiveSessionPool(maximumSessions: 1)
        for name in ["one", "two", "one"] { #expect(try await pool.read("data", from: work.file(name)) == Data([3])) }
        #expect(await pool.statistics().opens == 3)
        #expect(await pool.statistics().cachedSessions == 1)
        let tiny = try ArchiveSessionPool(maximumIndexBytes: 1)
        #expect(try await tiny.read("data", from: work.file("one")) == Data([3]))
        #expect(await tiny.statistics().cachedSessions == 0)
    }

    @Test
    func rejectsOverlongNamesWithoutTrapping() async throws {
        let work = try Workspace()
        let path = String(repeating: "a", count: 65_536)
        await #expect(throws: ArchiveFailure.unsafePath(path)) {
            try await ArchiveWriter().create(at: work.file("long.zip"), assets: [.init(path: path, content: .bytes(Data()))])
        }
    }

    @Test
    func truncatedAndForgedDirectoryAreRejected() async throws {
        let work = try Workspace()
        try await ArchiveWriter().create(at: work.file("valid.zip"), assets: [.init(path: "data", content: .bytes(Data([1, 2, 3])))])
        let valid = try Data(contentsOf: work.file("valid.zip"))
        for count in [0, 1, 20, valid.count - 1] {
            try valid.prefix(count).write(to: work.file("truncated.zip"))
            await #expect(throws: (any Error).self) { try await ArchiveReader.open(work.file("truncated.zip")) }
        }
        var forged = valid
        // EOCD entry counts must match the number of parsed directory records.
        forged[valid.count - 22 + 8] = 2
        forged[valid.count - 22 + 10] = 2
        try forged.write(to: work.file("forged.zip"))
        await #expect(throws: (any Error).self) { try await ArchiveReader.open(work.file("forged.zip")) }
    }

    @Test
    func bulkWriterEmitsZIP64DirectoryForLargeEntryCount() throws {
        let work = try Workspace()
        do {
            let writer = try BulkArchiveWriter(url: work.file("zip64.zip"), maximumBytes: 20_000_000)
            for index in 0..<65_536 {
                try writer.append(path: "\(index)", size: 0, deflate: false, bufferSize: 65_536) { _, _ in Data() }
            }
            try writer.finish()
        }
        let archive = try Archive(url: work.file("zip64.zip"), accessMode: .read)
        #expect(archive.declaredEntryCount == 65_536)
        #expect(Array(archive).count == 65_536)
    }

    @Test
    func failedBulkProviderNeverPublishes() async throws {
        let work = try Workspace()
        // A low output cap fails during writing, with the staging file removed.
        await #expect(throws: ArchiveFailure.archiveTooLarge) {
            try await ArchiveWriter().create(at: work.file("small.zip"), assets: [
                .init(path: "data", content: .bytes(Data(repeating: 1, count: 200_000)))
            ], limits: .init(maximumArchiveBytes: 100_000))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: work.root.path).isEmpty)
    }
}
