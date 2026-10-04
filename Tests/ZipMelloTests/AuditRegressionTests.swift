import Foundation
import Synchronization
import Testing
@testable import ZipMello

private final class AuditWorkspace: Sendable {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    init() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false) }
    deinit { try? FileManager.default.removeItem(at: root) }
    func file(_ name: String) -> URL { root.appendingPathComponent(name) }
}

@Suite struct AuditRegressionTests {
    private func archive(payload: Data, expanded: UInt64, checksum: UInt32, method: UInt16 = 8) -> Data {
        let name = Data("page".utf8)
        var local = ZipBinaryWriter.localFileHeader(nameData: name, method: method, zip64: false)
        local.withUnsafeMutableBytes { buffer in
            ZipBinaryBuffer.writeUInt32(checksum, into: buffer, offset: 14)
            ZipBinaryBuffer.writeUInt32(UInt32(payload.count), into: buffer, offset: 18)
            ZipBinaryBuffer.writeUInt32(UInt32(expanded), into: buffer, offset: 22)
        }
        let record = ZipBinaryWriter.centralDirectoryRecord(.init(path: "page", compressionMethod: method,
            crc32: checksum, compressedSize: UInt64(payload.count), uncompressedSize: expanded,
            localHeaderOffset: 0, isDirectory: false))
        var end = Data(count: 22)
        end.withUnsafeMutableBytes { buffer in
            ZipBinaryBuffer.writeUInt32(ZipMagic.endOfCentralDirectory, into: buffer, offset: 0)
            ZipBinaryBuffer.writeUInt16(1, into: buffer, offset: 8)
            ZipBinaryBuffer.writeUInt16(1, into: buffer, offset: 10)
            ZipBinaryBuffer.writeUInt32(UInt32(record.count), into: buffer, offset: 12)
            ZipBinaryBuffer.writeUInt32(UInt32(local.count + payload.count), into: buffer, offset: 16)
        }
        return local + payload + record + end
    }

    @Test(arguments: [UInt64(20_001), UInt64(Int.max), UInt64.max])
    func forgedZIP64CountsThrowBeforeAllocation(count: UInt64) async throws {
        var data = Data(count: 98)
        data.withUnsafeMutableBytes { buffer in
            ZipBinaryBuffer.writeUInt32(ZipMagic.zip64EOCDRecord, into: buffer, offset: 0)
            ZipBinaryBuffer.writeUInt64(44, into: buffer, offset: 4)
            ZipBinaryBuffer.writeUInt64(count, into: buffer, offset: 24)
            ZipBinaryBuffer.writeUInt64(count, into: buffer, offset: 32)
            ZipBinaryBuffer.writeUInt32(ZipMagic.zip64EOCDLocator, into: buffer, offset: 56)
            ZipBinaryBuffer.writeUInt32(1, into: buffer, offset: 72)
            ZipBinaryBuffer.writeUInt32(ZipMagic.endOfCentralDirectory, into: buffer, offset: 76)
            ZipBinaryBuffer.writeUInt16(UInt16.max, into: buffer, offset: 84)
            ZipBinaryBuffer.writeUInt16(UInt16.max, into: buffer, offset: 86)
            ZipBinaryBuffer.writeUInt32(UInt32.max, into: buffer, offset: 88)
            ZipBinaryBuffer.writeUInt32(UInt32.max, into: buffer, offset: 92)
        }
        #expect(throws: ArchiveFailure.tooManyEntries) { try ArchiveMemoryReader(data: data) }
        await #expect(throws: ArchiveFailure.tooManyEntries) { try await ArchiveReader.open(data: data) }
        #expect(throws: (any Error).self) { try ArchiveMemoryReader(data: data, limits: .init(maximumEntries: Int.max)) }
    }

    @Test func fastDeflateRejectsUnwrittenTail() throws {
        // Final stored DEFLATE block encoding five bytes.
        let packed = Data([1, 5, 0, 250, 255]) + Data("hello".utf8)
        var destination = Data(repeating: 0xA5, count: 20)
        #expect(throws: ArchiveFailure.sizeMismatch("page")) {
            try destination.withUnsafeMutableBytes {
                try ZipDeflateEngine.decompressWholeBuffer(compressed: packed, destination: $0, path: "page")
            }
        }
        let data = archive(payload: packed, expanded: 20, checksum: 0)
        #expect(throws: ArchiveFailure.sizeMismatch("page")) {
            try ArchiveMemoryReader(data: data, tuning: .smallEntries).read("page")
        }
    }

    @Test(arguments: [0, 4_194_304])
    func incompleteDeflateCannotValidateOrPublish(fastLimit: Int) async throws {
        let packed = Data([0, 5, 0, 250, 255]) + Data("hello".utf8)
        let data = archive(payload: packed, expanded: 5, checksum: ZipChecksum.update(data: Data("hello".utf8)))
        let reader = try await ArchiveReader.open(data: data, tuning: .init(wholeBufferDeflateLimit: fastLimit))
        await #expect(throws: (any Error).self) { try await reader.read("page") }
        await #expect(throws: (any Error).self) { try await reader.validate() }
        let work = try AuditWorkspace()
        await #expect(throws: (any Error).self) { try await reader.extract("page", to: work.file("output")) }
        #expect(!FileManager.default.fileExists(atPath: work.file("output").path))
    }

    @Test(arguments: [0, 4_194_304])
    func emptyDeflateStillValidatesStream(fastLimit: Int) throws {
        let tuning = ArchiveTuning(wholeBufferDeflateLimit: fastLimit)
        let valid = archive(payload: Data([3, 0]), expanded: 0, checksum: 0)
        #expect(try ArchiveMemoryReader(data: valid, tuning: tuning).read("page").isEmpty)
        for packed in [Data(), Data([0]), Data([255, 255])] {
            let invalid = archive(payload: packed, expanded: 0, checksum: 0)
            #expect(throws: (any Error).self) { try ArchiveMemoryReader(data: invalid, tuning: tuning).read("page") }
        }
    }

    @Test(arguments: [ArchiveCompression.stored, .deflate])
    func changedSourceNeverPublishes(compression: ArchiveCompression) async throws {
        let work = try AuditWorkspace()
        let source = work.file("source")
        try Data(repeating: 9, count: 100).write(to: source)
        await #expect(throws: (any Error).self) {
            try await ArchiveWriter().create(at: work.file("a.zip"), assets: [
                .init(path: "first", content: .bytes(Data([1]))),
                .init(path: "second", content: .file(source), compression: compression)
            ]) { progress in
                if progress.completedEntries == 1 { try? Data([9]).write(to: source) }
            }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: work.root.path) == ["source"])
        #expect(throws: (any Error).self) {
            _ = try ZipDeflateEngine.compress(uncompressedBytes: 10, provider: { offset, _ in
                offset == 0 ? Data([9]) : Data()
            }, consumer: { _ in })
        }
    }

    @Test func zip64ExtraCannotBorrowCommentBytes() throws {
        var data = archive(payload: Data([7]), expanded: 1, checksum: ZipChecksum.update(data: Data([7])), method: 0)
        let cd = try #require(data.range(of: Data([0x50, 0x4B, 1, 2]))).lowerBound
        data.insert(contentsOf: [1, 0, 8, 0, 1, 0, 0, 0, 0, 0, 0, 0], at: cd + 50)
        data.withUnsafeMutableBytes { buffer in
            ZipBinaryBuffer.writeUInt32(UInt32.max, into: buffer, offset: cd + 24)
            ZipBinaryBuffer.writeUInt16(4, into: buffer, offset: cd + 30)
            ZipBinaryBuffer.writeUInt16(8, into: buffer, offset: cd + 32)
            ZipBinaryBuffer.writeUInt32(62, into: buffer, offset: buffer.count - 10)
        }
        #expect(throws: (any Error).self) { try ArchiveMemoryReader(data: data) }
    }

    @Test(arguments: [UInt64(UInt32.max) - 1, UInt64(UInt32.max), UInt64(UInt32.max) + 1])
    func zip64EntryMetadataAtBoundary(size: UInt64) throws {
        let zip64 = ZipBinaryWriter.requiresZIP64LocalHeader(size: size, method: 0)
        let local = ZipBinaryWriter.localFileHeader(nameData: Data("page".utf8), method: 0, zip64: zip64)
        local.withUnsafeBytes { buffer in
            #expect(ZipBinaryBuffer.readUInt16(from: buffer, offset: 4) == (zip64 ? 45 : 20))
            #expect(ZipBinaryBuffer.readUInt16(from: buffer, offset: 28) == (zip64 ? 20 : 0))
        }
        let record = ZipBinaryWriter.centralDirectoryRecord(.init(path: "page", compressionMethod: 0,
            crc32: 0, compressedSize: size, uncompressedSize: size, localHeaderOffset: size,
            isDirectory: false, usesZIP64: zip64))
        record.withUnsafeBytes { buffer in
            #expect(ZipBinaryBuffer.readUInt16(from: buffer, offset: 30) == (zip64 ? 28 : 0))
            if zip64 {
                #expect(ZipBinaryBuffer.readUInt16(from: buffer, offset: 50) == 1)
                #expect(ZipBinaryBuffer.readUInt64(from: buffer, offset: 54) == size)
                #expect(ZipBinaryBuffer.readUInt64(from: buffer, offset: 62) == size)
                #expect(ZipBinaryBuffer.readUInt64(from: buffer, offset: 70) == size)
            }
        }
        var end = Data(count: 22)
        end.withUnsafeMutableBytes { buffer in
            ZipBinaryBuffer.writeUInt32(ZipMagic.endOfCentralDirectory, into: buffer, offset: 0)
            ZipBinaryBuffer.writeUInt16(1, into: buffer, offset: 8)
            ZipBinaryBuffer.writeUInt16(1, into: buffer, offset: 10)
            ZipBinaryBuffer.writeUInt32(UInt32(record.count), into: buffer, offset: 12)
        }
        let parsed = try ZipCentralDirectoryParser.parse(input: .bytes(record + end))
        let entry = try #require(parsed.entries.first)
        #expect(entry.uncompressedSize == size && entry.compressedSize == size && entry.localHeaderOffset == size)

    }

    @Test func zip64OffsetOnlyAndCompressionBound() {
        let size = UInt64(UInt32.max)
        #expect(ZipBinaryWriter.requiresZIP64LocalHeader(size: size - 1000, method: 8))
        let record = ZipBinaryWriter.centralDirectoryRecord(.init(path: "page", compressionMethod: 0,
            crc32: 0, compressedSize: 1, uncompressedSize: 1, localHeaderOffset: size,
            isDirectory: false))
        record.withUnsafeBytes { buffer in
            #expect(ZipBinaryBuffer.readUInt16(from: buffer, offset: 30) == 12)
            #expect(ZipBinaryBuffer.readUInt64(from: buffer, offset: 54) == size)
        }
    }

    @Test(arguments: [ArchiveCompression.stored, .deflate])
    func outputBudgetStopsBeforeOversizedEntryCompletes(compression: ArchiveCompression) async throws {
        let work = try AuditWorkspace()
        let completed = Mutex(0)
        await #expect(throws: ArchiveFailure.archiveTooLarge) {
            try await ArchiveWriter().create(at: work.file("small.zip"), assets: [
                .init(path: "page", content: .bytes(Data(repeating: 9, count: 200_000)), compression: compression)
            ], limits: .init(maximumArchiveBytes: 100)) { progress in
                completed.withLock { $0 = progress.completedEntries }
            }
        }
        #expect(completed.withLock { $0 } == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: work.root.path).isEmpty)
    }

    @Test func aliasCacheSharesPayloadWithoutChangingExactLookup() async throws {
        let work = try AuditWorkspace(), zip = work.file("a.zip")
        try await ArchiveWriter().create(at: zip, assets: [.init(path: "page", content: .bytes(Data([7])))])
        let store = try ArchivePageStore(directory: work.root, maximumFiles: 1)
        let first = try await store.lease("PAGE", from: zip, lookup: .compatible)
        let second = try await store.lease("page", from: zip, lookup: .exact)
        #expect(first.url == second.url)
        await #expect(throws: ArchiveFailure.missingEntry("PAGE")) { try await store.lease("PAGE", from: zip, lookup: .exact) }
        #expect(await store.statistics().extractions == 1)
        await first.release()
        await second.release()
        await store.removeAll()
        #expect(await store.statistics().bytes == 0)
    }

    @Test func memoryAliasIndexPreservesAmbiguityAndExactPrecedence() async throws {
        let work = try AuditWorkspace(), zip = work.file("a.zip")
        // Use the low-level writer because creating a colliding extraction tree is deliberately rejected.
        FileManager.default.createFile(atPath: zip.path, contents: nil)
        try ZipBinaryWriter.writeArchive(to: zip, assets: [
            .init(path: "Page", content: .bytes(Data([1]))), .init(path: "page", content: .bytes(Data([2])))
        ], sizes: [1, 1], limits: .init(), tuning: .init(), progress: nil, totalBytes: 2)
        let reader = try ArchiveMemoryReader(data: Data(contentsOf: zip), lookup: .compatible)
        #expect(try reader.read("Page") == Data([1]))
        #expect(try reader.read("page") == Data([2]))
        #expect(throws: ArchiveFailure.ambiguousEntry("PAGE")) { try reader.read("PAGE") }
    }

    @Test func cancelledQueuedPagesDoNotExtract() async throws {
        let work = try AuditWorkspace(), zip = work.file("a.zip")
        try await ArchiveWriter().create(at: zip, assets: (0..<16).map {
            .init(path: "page\($0)", content: .bytes(Data(repeating: 9, count: 2_000_000)))
        })
        let store = try ArchivePageStore(directory: work.root, maximumExtractions: 1, limits: .init(bufferBytes: 1024))
        let tasks = (0..<16).map { number in Task { try await store.lease("page\(number)", from: zip) } }
        for _ in 0..<1000 {
            if await store.statistics().queuedRequests >= 8 { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(await store.statistics().queuedRequests >= 8)
        for task in tasks { task.cancel() }
        for task in tasks { if let lease = try? await task.value { await lease.release() } }
        #expect(await store.statistics().files < 16)
        // Drain cancelled workers; reuse the store afterwards to catch leaked permits/reservations.
        await store.removeAll()
        let stats = await store.statistics()
        #expect(stats.cancelledBeforeExtraction > 0)
        #expect(stats.files == 0 && stats.bytes == 0)
        let lease = try await store.lease("page0", from: zip)
        #expect(try Data(contentsOf: lease.url).count == 2_000_000)
        await lease.release()
        await store.removeAll()
    }

    @Test func cancellingOneCoalescedWaiterPreservesTheOther() async throws {
        let work = try AuditWorkspace(), zip = work.file("a.zip")
        let payload = Data(repeating: 7, count: 4_000_000)
        try await ArchiveWriter().create(at: zip, assets: [.init(path: "page", content: .bytes(payload))])
        let store = try ArchivePageStore(directory: work.root, maximumExtractions: 1, limits: .init(bufferBytes: 64))
        let cancelled = Task { try await store.lease("page", from: zip) }
        let survivor = Task { try await store.lease("page", from: zip) }
        for _ in 0..<1000 {
            if await store.statistics().bytes > 0 { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        try await Task.sleep(for: .milliseconds(10))
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        let page = try await survivor.value
        #expect(try Data(contentsOf: page.url) == payload)
        #expect(await store.statistics().extractions == 1)
        #expect(await store.statistics().cancelledBeforeExtraction == 0)
        await page.release()
        await store.removeAll()
    }

    @Test func clearingAnActiveQueueDrainsReservationsAndRemainsReusable() async throws {
        let work = try AuditWorkspace(), zip = work.file("a.zip")
        try await ArchiveWriter().create(at: zip, assets: (0..<8).map {
            .init(path: "page\($0)", content: .bytes(Data(repeating: 9, count: 2_000_000)))
        })
        let store = try ArchivePageStore(directory: work.root, maximumExtractions: 1, limits: .init(bufferBytes: 256))
        let tasks = (0..<8).map { number in Task { try await store.lease("page\(number)", from: zip) } }
        for _ in 0..<1000 {
            if await store.statistics().queuedRequests >= 4 { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(await store.statistics().queuedRequests >= 4)
        await store.removeAll()
        for task in tasks { if let lease = try? await task.value { await lease.release() } }
        let stats = await store.statistics()
        #expect(stats.bytes == 0 && stats.files == 0 && stats.activeLeases == 0)
        let next = try await store.lease("page0", from: zip)
        await next.release()
        await store.removeAll()
    }

    @Test func requestsAcrossArchivesRespectOpenCapacity() async throws {
        let work = try AuditWorkspace()
        for number in 0..<8 {
            try await ArchiveWriter().create(at: work.file("\(number).zip"), assets: [
                .init(path: "page", content: .bytes(Data([UInt8(number)])))
            ])
        }
        let store = try ArchivePageStore(directory: work.root, maximumExtractions: 1)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for number in 0..<8 {
                group.addTask {
                    let lease = try await store.lease("page", from: work.file("\(number).zip"))
                    #expect(try Data(contentsOf: lease.url) == Data([UInt8(number)]))
                    await lease.release()
                }
            }
            try await group.waitForAll()
        }
        await store.removeAll()
        #expect(await store.statistics().bytes == 0)
    }
}
