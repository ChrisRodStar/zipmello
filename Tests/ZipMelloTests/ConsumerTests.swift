import Foundation
import Synchronization
import Testing
@testable import ZipMello
import ZipMelloConsumers

private final class ConsumerWorkspace: Sendable {
    let root: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    func file(_ path: String) -> URL { root.appendingPathComponent(path) }
    func upstream(_ paths: [String], bytes: Data = Data("payload".utf8)) async throws -> URL {
        let url = file(UUID().uuidString + ".zip")
        let assets = paths.map { path -> ArchiveAsset in
            if path.hasSuffix("/") {
                return ArchiveAsset(path: path, content: .directory)
            } else {
                return ArchiveAsset(path: path, content: .bytes(bytes))
            }
        }
        let sizes = assets.map { asset -> UInt64 in
            if case .directory = asset.content { return 0 } else { return UInt64(bytes.count) }
        }
        let total = sizes.reduce(0, +)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        try ZipBinaryWriter.writeArchive(to: url, assets: assets, sizes: sizes, limits: .init(), tuning: .init(), progress: nil, totalBytes: total)
        return url
    }
}

@Suite struct ConsumerTests {
    @Test(arguments: ["descriptor32", "descriptor64", "descriptor-unsigned", "zip64-zero", "cp437"])
    func `External data descriptors ZIP64 local headers and CP437 names interoperate`(fixture: String) async throws {
        let url = try #require(Bundle.module.url(forResource: fixture, withExtension: "zip", subdirectory: "Fixtures"))
        let reader = try await ArchiveReader.open(url)
        let path = fixture == "cp437" ? "café.txt" : fixture == "zip64-zero" ? "zero.txt" : "日本語/page.txt"
        let expected = fixture == "cp437" ? Data("legacy encoding".utf8) : fixture == "zip64-zero" ? Data() : Data(String(repeating: "external descriptor payload", count: 100).utf8)
        #expect(try await reader.read(path) == expected)
        let memory = try await ArchiveReader.open(data: Data(contentsOf: url))
        #expect(try await memory.read(path) == expected)
    }

    @Test(arguments: [ArchiveCompression.stored, .deflate])
    func `Downloaded bytes and sliced Data read without a spool`(compression: ArchiveCompression) async throws {
        let work = try ConsumerWorkspace(), bytes = Data(repeating: 42, count: 300_000)
        let url = work.file("remote.zip")
        try await ArchiveWriter().create(at: url, assets: [.init(path: "日本語/chapter.md", content: .bytes(bytes), compression: compression)])
        let data = try Data(contentsOf: url)
        var envelope = Data([1, 2, 3]); envelope.append(data)
        let reader = try await ArchiveReader.open(data: envelope.dropFirst(3), limits: .sourcePages, tuning: .pagePrefetch)
        #expect(try await reader.read("日本語/chapter.md") == bytes)
        #expect(try ArchiveMemoryReader(data: envelope.dropFirst(3), limits: .sourcePages).read("日本語/chapter.md") == bytes)
        #expect(try await ArchiveMemoryService.shared.read("日本語/chapter.md", data: data) == bytes)
        try await reader.validate()
        await #expect(throws: ArchiveFailure.archiveTooLarge) {
            try await ArchiveReader.open(data: data, limits: .init(maximumArchiveBytes: 1))
        }
        await #expect(throws: ArchiveFailure.invalidLimits) {
            try await ArchiveReader.open(data: data, limits: .init(maximumEntryBytes: .max))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: work.root.path) == ["remote.zip"])
    }

    @Test func `Compatible lookup resolves aliases and prefers exact paths`() async throws {
        let work = try ConsumerWorkspace()
        let url = try await work.upstream(["./OEBPS/images/plate%20one.png", "OEBPS/Cover.PNG"])
        let reader = try await ArchiveReader.open(url)
        #expect(try await reader.read("oebps/images/plate one.png", lookup: .compatible) == Data("payload".utf8))
        #expect(try ArchiveMemoryReader(data: Data(contentsOf: url), lookup: .compatible).read("oebps/images/plate one.png") == Data("payload".utf8))
        #expect(try await reader.read("OEBPS/cover.png", lookup: .compatible) == Data("payload".utf8))
        await #expect(throws: ArchiveFailure.missingEntry("OEBPS/cover.png")) { try await reader.read("OEBPS/cover.png") }
        #expect(try await reader.member("OEBPS/Cover.PNG", lookup: .compatible).path == "OEBPS/Cover.PNG")
    }

    @Test func `Ambiguous aliases fail while exact names remain readable`() async throws {
        let work = try ConsumerWorkspace()
        let url = try await work.upstream(["Cover.PNG", "cover.png", "safe%2F..%2Fescape"])
        let reader = try await ArchiveReader.open(url)
        await #expect(throws: ArchiveFailure.ambiguousEntry("COVER.PNG")) { try await reader.read("COVER.PNG", lookup: .compatible) }
        #expect(try await reader.read("cover.png", lookup: .compatible) == Data("payload".utf8))
        await #expect(throws: ArchiveFailure.unsafePath("safe/../escape")) { try await reader.read("safe/../escape", lookup: .compatible) }
        #expect(try await reader.read("safe%2F..%2Fescape", lookup: .compatible) == Data("payload".utf8))
    }

    @Test func `Tree extraction handles Payload and empty directories`() async throws {
        let work = try ConsumerWorkspace()
        let url = try await work.upstream(["./", "./Payload/source.json", "Payload/nested/main.wasm", "empty/"])
        let reader = try await ArchiveReader.open(url)
        let events = Mutex<[ArchiveProgress]>([])
        try await reader.extractAll(to: work.file("installed")) { event in events.withLock { $0.append(event) } }
        #expect(try Data(contentsOf: work.file("installed/Payload/nested/main.wasm")) == Data("payload".utf8))
        #expect(try work.file("installed/empty").resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true)
        #expect(events.withLock { $0.last?.completedEntries } == 2)
        await #expect(throws: ArchiveFailure.destinationExists) { try await reader.extractAll(to: work.file("installed")) }
    }

    @Test(arguments: [["A/page", "a/page"], ["file", "file/page"], ["./page", "page"], ["é/page", "e\u{301}/page"]])
    func `Tree collisions never publish`(paths: [String]) async throws {
        let work = try ConsumerWorkspace()
        let url = try await work.upstream(paths)
        await #expect(throws: (any Error).self) {
            let reader = try await ArchiveReader.open(url)
            try await reader.extractAll(to: work.file("bad"))
        }
        #expect(!FileManager.default.fileExists(atPath: work.file("bad").path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: work.root.path).allSatisfy { !$0.hasPrefix(".tree-") })
    }

    @Test func `CRC preflight and tree extraction reject corrupted payloads`() async throws {
        let work = try ConsumerWorkspace(), bytes = Data("unique-crc-payload".utf8)
        let url = try await work.upstream(["nested/page"], bytes: bytes)
        var zip = try Data(contentsOf: url)
        let range = try #require(zip.range(of: bytes)); zip[range.lowerBound] ^= 1; try zip.write(to: url)
        let reader = try await ArchiveReader.open(url)
        await #expect(throws: ArchiveFailure.checksumMismatch("nested/page")) { try await reader.validate() }
        await #expect(throws: ArchiveFailure.checksumMismatch("nested/page")) { try await reader.extractAll(to: work.file("bad")) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: work.root.path).count == 1)
    }

    @Test func `Cancellation during tree progress removes partial files`() async throws {
        let work = try ConsumerWorkspace()
        let reader = try await ArchiveReader.open(await work.upstream(["one", "two"]))
        let task = Task {
            try await reader.extractAll(to: work.file("cancelled")) { progress in
                if progress.completedEntries == 1 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: work.file("cancelled").path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: work.root.path).allSatisfy { !$0.hasPrefix(".tree-") })
    }

    @Test func `Recursive export preserves sidecars metadata and empty folders`() async throws {
        let work = try ConsumerWorkspace(), source = work.file("source")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("nested/empty"), withIntermediateDirectories: true)
        for path in ["1.png", "10.png", "2.png", "2.desc.txt", ".metadata.json", "ComicInfo.xml", "nested/page.md"] {
            try Data(path.utf8).write(to: source.appendingPathComponent(path))
        }
        let events = Mutex<[ArchiveProgress]>([])
        try await ArchiveWriter().create(at: work.file("chapter.cbz"), directory: source) { event in events.withLock { $0.append(event) } }
        let reader = try await ArchiveReader.open(work.file("chapter.cbz"))
        let members = try await reader.listing()
        #expect(members.first(where: { $0.path == "nested/empty" || $0.path == "nested/empty/" })?.isDirectory == true)
        #expect(members.first(where: { $0.path == "source/1.png" }) == nil)
        #expect(members.first(where: { $0.path == ".metadata.json" }) != nil)
        let paths = members.map(\.path)
        #expect(try #require(paths.firstIndex(of: "2.png")) < #require(paths.firstIndex(of: "10.png")))
        #expect(try await reader.read("2.desc.txt") == Data("2.desc.txt".utf8))
        let values = events.withLock { $0 }
        #expect(values.last?.completedBytes == values.last?.totalBytes)
        #expect(values.last?.completedEntries == values.last?.totalEntries)
        #expect(zip(values, values.dropFirst()).allSatisfy { $0.completedBytes <= $1.completedBytes })
    }

    @Test func `Recursive export rejects links and leaves no archive`() async throws {
        let work = try ConsumerWorkspace()
        try FileManager.default.createDirectory(at: work.file("source"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: work.file("source/link"), withDestinationURL: work.file("outside"))
        await #expect(throws: ArchiveFailure.unsupportedEntry("link")) {
            try await ArchiveWriter().create(at: work.file("bad.zip"), directory: work.file("source"))
        }
        #expect(!FileManager.default.fileExists(atPath: work.file("bad.zip").path))
    }

    @Test func `Concurrent page requests share one extracted file and retain active leases`() async throws {
        let work = try ConsumerWorkspace(), url = work.file("pages.cbz")
        try await ArchiveWriter().create(at: url, assets: [.init(path: "page.png", content: .bytes(Data(repeating: 7, count: 200_000)))])
        let store = try ArchivePageStore(directory: work.root)
        let leases = try await withThrowingTaskGroup(of: ArchiveFileLease.self) { group in
            for _ in 0..<20 { group.addTask { try await store.lease("page.png", from: url) } }
            var files: [ArchiveFileLease] = []
            for try await file in group { files.append(file) }
            return files
        }
        #expect(Set(leases.map(\.url)).count == 1)
        #expect(await store.statistics().extractions == 1)
        #expect(await store.statistics().activeLeases == 20)
        await store.removeAll()
        #expect(try Data(contentsOf: leases[0].url).count == 200_000)
        for lease in leases { await lease.release(); await lease.release() }
        #expect(!FileManager.default.fileExists(atPath: leases[0].url.path))
        #expect(await store.statistics().activeLeases == 0)
    }

    @Test func `Page budgets preserve leased pages and invalidate replaced archives`() async throws {
        let work = try ConsumerWorkspace(), url = work.file("pages.cbz")
        let writer = ArchiveWriter()
        try await writer.create(at: url, assets: [.init(path: "one", content: .bytes(Data(repeating: 1, count: 10))), .init(path: "two", content: .bytes(Data(repeating: 2, count: 10)))])
        let store = try ArchivePageStore(directory: work.root, maximumBytes: 10, maximumFiles: 1)
        let session = try await store.session(for: url)
        let first = try await session.lease("one")
        await #expect(throws: ArchiveFailure.cacheCapacityExceeded) { try await store.lease("two", from: url) }
        #expect(try Data(contentsOf: first.url) == Data(repeating: 1, count: 10))
        await first.release()
        let second = try await store.lease("two", from: url)
        #expect(!FileManager.default.fileExists(atPath: first.url.path))
        await second.release()
        try FileManager.default.removeItem(at: url)
        try await writer.create(at: url, assets: [.init(path: "two", content: .bytes(Data(repeating: 3, count: 10)))])
        let replaced = try await store.lease("two", from: url)
        #expect(try Data(contentsOf: replaced.url) == Data(repeating: 3, count: 10))
        await replaced.release(); await store.removeAll()
    }

    @Test func `Local comics naturally order text and images and lazily load metadata`() async throws {
        let work = try ConsumerWorkspace()
        let metadata = ComicInfo(fields: ["Title": "A & B <日本語>", "Number": "1.5", "Notes": "!AIDOKUDATA:{\"id\":\"123\"}", "Manga": "YesAndRightToLeft"], pages: [["Image": "0", "Type": "FrontCover"]])
        let url = work.file("chapter.zip")
        try await ArchiveWriter().create(at: url, assets: [
            .init(path: "10.png", content: .bytes(Data([10]))), .init(path: "2.md", content: .bytes(Data("# Text".utf8))),
            .init(path: "1.png", content: .bytes(Data([1]))), .init(path: "2.desc.txt", content: .bytes(Data("Description".utf8))),
            .init(path: "nested/ComicInfo.xml", content: .bytes(ComicInfoCodec.encode(metadata))),
            .init(path: ".hidden.png", content: .bytes(Data())), .init(path: "__MACOSX/extra.png", content: .bytes(Data()))
        ])
        let comic = try await LocalComicArchive.open(url)
        #expect(comic.pages.map(\.path) == ["1.png", "2.md", "10.png"])
        #expect(try await comic.text(at: 1) == "# Text")
        #expect(try await comic.description(at: 1) == "Description")
        #expect(try await comic.coverBytes() == Data([1]))
        #expect(try await comic.comicInfo() == metadata)
        await comic.close()
    }

    @Test(arguments: [String.Encoding.utf8, .utf16])
    func `ComicInfo rejects external entities and preserves escaped values`(encoding: String.Encoding) throws {
        let metadata = ComicInfo(fields: ["Summary": "& < > \" '\n日本語"], pages: [["Image": "0"]])
        #expect(try ComicInfoCodec.decode(ComicInfoCodec.encode(metadata)) == metadata)
        let encoded = try #require("<ComicInfo><Title>日本語</Title></ComicInfo>".data(using: encoding))
        #expect(try ComicInfoCodec.decode(encoded)["Title"] == "日本語")
        #expect(throws: ComicInfoError.invalidXML) { try ComicInfoCodec.decode(Data("<!DOCTYPE ComicInfo [<!ENTITY x SYSTEM 'file:///etc/passwd'>]><ComicInfo><Title>&x;</Title></ComicInfo>".utf8)) }
        #expect(throws: ComicInfoError.invalidName("Title><bad")) { try ComicInfoCodec.encode(ComicInfo(fields: ["Title><bad": "x"])) }
    }

    @Test func `Streaming consumption validates every byte without retaining member output`() async throws {
        let work = try ConsumerWorkspace(), bytes = Data(repeating: 9, count: 200_000)
        let url = work.file("stream.zip")
        try await ArchiveWriter().create(at: url, assets: [.init(path: "member", content: .bytes(bytes), compression: .deflate)])
        let reader = try await ArchiveReader.open(url, limits: .init(bufferBytes: 4_096), tuning: .pagePrefetch)
        let count = Mutex(0)
        try await reader.consume("member") { chunk in
            #expect(chunk.allSatisfy { $0 == 9 })
            count.withLock { $0 += chunk.count }
        }
        #expect(count.withLock { $0 } == bytes.count)
    }

    @Test func `Cancellation during export progress removes staging`() async throws {
        let work = try ConsumerWorkspace()
        let task = Task {
            try await ArchiveWriter().create(at: work.file("cancelled.zip"), assets: [
                .init(path: "one", content: .bytes(Data(repeating: 9, count: 200_000))),
                .init(path: "two", content: .bytes(Data([1])))
            ]) { progress in
                if progress.completedBytes > 0 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try FileManager.default.contentsOfDirectory(atPath: work.root.path).isEmpty)
    }

    @Test func `Dictionary preflight verifies metadata and rejects escaping native titles`() async throws {
        let work = try ConsumerWorkspace()
        let writer = ArchiveWriter(), url = work.file("dictionary.zip")
        try await writer.create(at: url, assets: [.init(path: "index.json", content: .bytes(Data("{\"title\":\"Dictionary\"}".utf8)), compression: .deflate), .init(path: "term_bank_1.json", content: .bytes(Data("[]".utf8)), compression: .deflate)])
        let inspection = try await DictionaryArchivePreflight.validate(url)
        #expect(inspection.title == "Dictionary")
        #expect(inspection.entries == 2)
        try await writer.create(at: work.file("bad.zip"), assets: [.init(path: "index.json", content: .bytes(Data("{\"title\":\"../escape\"}".utf8)))])
        await #expect(throws: ArchiveFailure.unsafePath("../escape")) { try await DictionaryArchivePreflight.validate(work.file("bad.zip")) }
    }
}
