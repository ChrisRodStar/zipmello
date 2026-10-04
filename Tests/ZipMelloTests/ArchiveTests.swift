import Foundation
import Testing
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
        let file = work.file("bad.zip")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        try ZipBinaryWriter.writeArchive(to: file, assets: [.init(path: "../escape", content: .bytes(Data([1])))], sizes: [1], limits: .init(), tuning: .init(), progress: nil, totalBytes: 1)
        await #expect(throws: ArchiveFailure.unsafePath("../escape")) { try await ArchiveReader.open(file) }
    }

    @Test
    func rejectsUnsupportedCompressionMethod() async throws {
        let work = try Workspace()
        let file = work.file("unsupported.zip")
        try await ArchiveWriter().create(at: file, assets: [.init(path: "page.txt", content: .bytes(Data("hello".utf8)), compression: .stored)])
        var bytes = try Data(contentsOf: file)
        let cdMagic = Data([0x50, 0x4b, 0x01, 0x02])
        let range = try #require(bytes.range(of: cdMagic))
        bytes[range.lowerBound + 10] = 9
        bytes[range.lowerBound + 11] = 0
        try bytes.write(to: file)
        await #expect(throws: ArchiveFailure.unsupportedEntry("Compression method 9 for 'page.txt'")) {
            try await ArchiveReader.open(file)
        }
    }

    @Test
    func rejectsSymlinksOnOpen() async throws {
        let work = try Workspace()
        let file = work.file("link.zip")
        let nameData = Data("link".utf8)
        var data = Data()
        var lh = Data(count: 30 + nameData.count)
        lh.withUnsafeMutableBytes { buf in
            ZipBinaryBuffer.writeUInt32(ZipMagic.localHeader, into: buf, offset: 0)
            ZipBinaryBuffer.writeUInt16(20, into: buf, offset: 4)
            ZipBinaryBuffer.writeUInt16(UInt16(nameData.count), into: buf, offset: 26)
        }
        lh.replaceSubrange(30..<30+nameData.count, with: nameData)
        data.append(lh)
        let cdOffset = UInt64(data.count)
        var cd = Data(count: 46 + nameData.count)
        cd.withUnsafeMutableBytes { buf in
            ZipBinaryBuffer.writeUInt32(ZipMagic.centralDirectoryHeader, into: buf, offset: 0)
            ZipBinaryBuffer.writeUInt16(20, into: buf, offset: 4)
            ZipBinaryBuffer.writeUInt16(20, into: buf, offset: 6)
            ZipBinaryBuffer.writeUInt16(UInt16(nameData.count), into: buf, offset: 28)
            ZipBinaryBuffer.writeUInt32(0xA1FF0000, into: buf, offset: 38)
            ZipBinaryBuffer.writeUInt32(0, into: buf, offset: 42)
        }
        cd.replaceSubrange(46..<46+nameData.count, with: nameData)
        data.append(cd)
        let cdSize = UInt64(cd.count)
        var eocd = Data(count: 22)
        eocd.withUnsafeMutableBytes { buf in
            ZipBinaryBuffer.writeUInt32(ZipMagic.endOfCentralDirectory, into: buf, offset: 0)
            ZipBinaryBuffer.writeUInt16(1, into: buf, offset: 8)
            ZipBinaryBuffer.writeUInt16(1, into: buf, offset: 10)
            ZipBinaryBuffer.writeUInt32(UInt32(cdSize), into: buf, offset: 12)
            ZipBinaryBuffer.writeUInt32(UInt32(cdOffset), into: buf, offset: 16)
        }
        data.append(eocd)
        try data.write(to: file)
        await #expect(throws: ArchiveFailure.unsupportedEntry("link")) { try await ArchiveReader.open(file) }
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
        let dupFile = work.file("duplicate.zip")
        FileManager.default.createFile(atPath: dupFile.path, contents: nil)
        try ZipBinaryWriter.writeArchive(to: dupFile, assets: [asset, asset], sizes: [0, 0], limits: .init(), tuning: .init(), progress: nil, totalBytes: 0)
        await #expect(throws: ArchiveFailure.duplicatePath("page")) { try await ArchiveReader.open(dupFile) }
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
    func bulkWriterEmitsZIP64DirectoryForLargeEntryCount() async throws {
        let work = try Workspace()
        let assets = (0..<65_536).map { ArchiveAsset(path: "\($0)", content: .bytes(Data())) }
        try await ArchiveWriter().create(at: work.file("zip64.zip"), assets: assets, limits: .init(maximumEntries: 70_000))
        let reader = try await ArchiveReader.open(work.file("zip64.zip"), limits: .init(maximumEntries: 70_000))
        #expect(try await reader.listing().count == 65_536)
        await reader.close()
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

    @Test
    func convenienceAPIsWorkAsExpected() async throws {
        let work = try Workspace()
        let zipURL = work.file("convenience.zip")
        let assetData = Data("convenience payload".utf8)
        
        try await ArchiveWriter.create(at: zipURL, assets: [
            .init(path: "test.txt", content: .bytes(assetData))
        ])

        let readData = try await ArchiveReader.read(entry: "test.txt", from: zipURL)
        #expect(readData == assetData)

        let extractURL = work.file("extracted.txt")
        try await ArchiveReader.extract(entry: "test.txt", from: zipURL, to: extractURL)
        #expect(try Data(contentsOf: extractURL) == assetData)

        let folderURL = work.file("out_folder")
        try await ArchiveReader.extractAll(from: zipURL, to: folderURL)
        #expect(try Data(contentsOf: folderURL.appendingPathComponent("test.txt")) == assetData)
    }

    @Test
    func deflateStreamTerminationWithTrailingInput() throws {
        let original = Data("payload data to be compressed and tested with trailing bytes".utf8)
        var compressed = Data()
        _ = try ZipDeflateEngine.compress(
            uncompressedBytes: UInt64(original.count),
            provider: { offset, count in original.subdata(in: Int(offset)..<(Int(offset) + count)) },
            consumer: { compressed.append($0) }
        )
        // Append extra trailing junk bytes simulating extra unconsumed provider buffer
        var padded = compressed
        padded.append(contentsOf: [0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x01, 0x02, 0x03])

        var decompressed = Data()
        let crc = try ZipDeflateEngine.decompress(
            compressedBytes: UInt64(padded.count),
            provider: { offset, count in
                let start = Int(offset)
                let end = Swift.min(start + count, padded.count)
                guard start < end else { return Data() }
                return padded.subdata(in: start..<end)
            },
            consumer: { decompressed.append($0) }
        )
        #expect(decompressed == original)
        #expect(crc == ZipChecksum.update(data: original))
    }

    @Test
    func eocdParsesArchiveWithComment() async throws {
        let work = try Workspace()
        let file = work.file("commented.zip")
        try await ArchiveWriter().create(at: file, assets: [
            .init(path: "item.txt", content: .bytes(Data("sample".utf8)))
        ])
        // Append a zip comment to the EOCD record
        var fileData = try Data(contentsOf: file)
        let comment = Data("Hello ZIP comment".utf8)
        let count = fileData.count
        fileData.withUnsafeMutableBytes { ptr in
            ZipBinaryBuffer.writeUInt16(UInt16(comment.count), into: ptr, offset: count - 2)
        }
        fileData.append(comment)
        try fileData.write(to: file)

        let reader = try await ArchiveReader.open(file)
        #expect(try await reader.listing().map(\.path) == ["item.txt"])
        #expect(try await reader.read("item.txt") == Data("sample".utf8))
        await reader.close()
    }
}

