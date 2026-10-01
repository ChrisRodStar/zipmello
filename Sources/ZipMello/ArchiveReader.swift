import Foundation
import Dispatch
import SystemPackage
import Darwin

/// Manages an immutable, open file descriptor for an archive file, closed when deallocated.
final class ArchiveFile: Sendable {
    let url: URL
    let rawDescriptor: Int32
    var descriptor: FileDescriptor {
        FileDescriptor(rawValue: rawDescriptor)
    }
    let bytes: UInt64
    let identity: ArchiveFileIdentity

    init(_ url: URL, bypassFileCache: Bool) throws {
        let descriptor = try FileDescriptor.open(url.path, .readOnly, options: [.noFollow])
        if bypassFileCache && fcntl(descriptor.rawValue, F_NOCACHE, 1) != 0 {
            try? descriptor.close()
            throw ArchiveFailure.invalidSource(url.path)
        }

        do {
            let identity = try ArchiveFileIdentity(fileDescriptor: descriptor.rawValue)
            self.url = url
            self.rawDescriptor = descriptor.rawValue
            self.bytes = UInt64(identity.bytes)
            self.identity = identity
        } catch {
            try? descriptor.close()
            throw error
        }
    }

    deinit {
        try? descriptor.close()
    }

    /// Verifies that neither the path on disk nor the open file descriptor has changed identity since opening.
    func validateIdentity(at url: URL) throws {
        guard identity.matches(url: url) else {
            throw ArchiveFailure.invalidSource("Archive changed during open")
        }
        guard identity.matches(fileDescriptor: rawDescriptor) else {
            throw ArchiveFailure.invalidSource("Archive descriptor changed")
        }
    }

    /// Performs a positional read (`pread`) without altering any shared file seek cursor.
    func read(offset: UInt64, count: Int) throws -> Data {
        guard count >= 0, offset <= bytes, UInt64(count) <= bytes - offset else {
            throw ArchiveFailure.invalidSource("Entry extends beyond archive")
        }
        if count == 0 {
            return Data()
        }

        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: count,
            alignment: MemoryLayout<UInt64>.alignment
        )
        do {
            let target = UnsafeMutableRawBufferPointer(start: storage, count: count)
            var completed = 0
            while completed < count {
                try Task.checkCancellation()
                let part = UnsafeMutableRawBufferPointer(rebasing: target[completed...])
                let read = try descriptor.read(fromAbsoluteOffset: Int64(offset) + Int64(completed), into: part)
                guard read > 0 else {
                    throw ArchiveFailure.invalidSource("Truncated archive")
                }
                completed += read
            }
        } catch {
            storage.deallocate()
            throw error
        }
        return Data(bytesNoCopy: storage, count: count, deallocator: .custom { pointer, _ in
            pointer.deallocate()
        })
    }
}

/// Abstract archive input source backed either by a filesystem file or in-memory `Data`.
enum ArchiveInput: Sendable {
    case file(ArchiveFile)
    case bytes(Data)

    var count: UInt64 {
        switch self {
        case .file(let file):
            return file.bytes
        case .bytes(let data):
            return UInt64(data.count)
        }
    }

    func validateIdentity() throws {
        if case .file(let file) = self {
            try file.validateIdentity(at: file.url)
        }
    }

    func read(offset: UInt64, count: Int) throws -> Data {
        switch self {
        case .file(let file):
            return try file.read(offset: offset, count: count)
        case .bytes(let data):
            guard count >= 0,
                  offset <= UInt64(data.count),
                  UInt64(count) <= UInt64(data.count) - offset else {
                throw ArchiveFailure.invalidSource("Entry extends beyond archive")
            }
            let start = data.startIndex + Int(offset)
            return data.subdata(in: start..<(start + count))
        }
    }
}

/// Worker executing raw payload reads, streaming decompression, and CRC validation for an entry.
struct ArchiveReadWorker: Sendable {
    private let input: ArchiveInput
    private let limits: ArchiveLimits
    private let tuning: ArchiveTuning

    init(input: ArchiveInput, limits: ArchiveLimits, tuning: ArchiveTuning) {
        self.input = input
        self.limits = limits
        self.tuning = tuning
    }

    func validateIdentity() throws {
        try input.validateIdentity()
    }

    func read(_ entry: ArchiveReadDescriptor, path: String) throws -> Data {
        var output = Data()
        output.reserveCapacity(Int(entry.expandedBytes))
        try consume(entry, path: path) { chunk in
            output.append(chunk)
        }
        return output
    }

    func extract(
        _ entry: ArchiveReadDescriptor,
        path: String,
        to destination: URL,
        durability: ArchiveDurability
    ) throws {
        try Task.checkCancellation()
        guard destination.isFileURL else {
            throw ArchiveFailure.invalidSource(destination.absoluteString)
        }
        let fm = FileManager.default
        guard !fm.fileExists(atPath: destination.path) else {
            throw ArchiveFailure.destinationExists
        }

        let staging = destination.deletingLastPathComponent().appendingPathComponent(".extract-" + UUID().uuidString)
        defer {
            try? fm.removeItem(at: staging)
        }

        let descriptor = try FileDescriptor.open(
            staging.path,
            .writeOnly,
            options: [.create, .exclusiveCreate, .noFollow],
            permissions: .ownerReadWrite
        )
        do {
            try consume(entry, path: path) { chunk in
                try descriptor.writeAll(chunk)
            }
            if durability == .synchronized && fsync(descriptor.rawValue) != 0 {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            try descriptor.close()
        } catch {
            try? descriptor.close()
            throw error
        }

        try Task.checkCancellation()
        try fm.moveItem(at: staging, to: destination)
    }

    func consume(
        _ entry: ArchiveReadDescriptor,
        path: String,
        consumer: (Data) throws -> Void
    ) throws {
        try Task.checkCancellation()
        var emitted: UInt64 = 0
        let crc: UInt32

        if entry.compression == .deflate {
            crc = try ZipDeflateEngine.decompress(
                compressedBytes: entry.compressedBytes,
                bufferBytes: limits.bufferBytes,
                provider: { offset, count in
                    try self.input.read(offset: entry.offset + offset, count: count)
                },
                consumer: { chunk in
                    try Task.checkCancellation()
                    let sum = emitted.addingReportingOverflow(UInt64(chunk.count))
                    guard !sum.overflow,
                          sum.partialValue <= entry.expandedBytes,
                          sum.partialValue <= limits.maximumEntryBytes else {
                        throw ArchiveFailure.memberTooLarge(path)
                    }
                    emitted = sum.partialValue
                    try consumer(chunk)
                }
            )
        } else {
            var readOffset: UInt64 = 0
            var runningCRC: UInt32 = 0
            while readOffset < entry.compressedBytes {
                try Task.checkCancellation()
                let fetchCount = Int(Swift.min(UInt64(limits.bufferBytes), entry.compressedBytes - readOffset))
                let chunk = try self.input.read(offset: entry.offset + readOffset, count: fetchCount)
                guard !chunk.isEmpty else { break }
                readOffset += UInt64(chunk.count)

                let sum = emitted.addingReportingOverflow(UInt64(chunk.count))
                guard !sum.overflow,
                      sum.partialValue <= entry.expandedBytes,
                      sum.partialValue <= limits.maximumEntryBytes else {
                    throw ArchiveFailure.memberTooLarge(path)
                }
                emitted = sum.partialValue
                runningCRC = ZipChecksum.update(current: runningCRC, data: chunk)
                try consumer(chunk)
            }
            crc = runningCRC
        }

        guard emitted == entry.expandedBytes else {
            throw ArchiveFailure.sizeMismatch(path)
        }
        guard crc == entry.checksum else {
            throw ArchiveFailure.checksumMismatch(path)
        }
    }
}

/// An independent parallel read lane dispatched onto its own dedicated serial queue.
private actor ArchiveReadLane {
    private nonisolated let executor = DispatchSerialQueue(label: "ZipMello.read-lane", qos: .utility)
    nonisolated var unownedExecutor: UnownedSerialExecutor {
        executor.asUnownedSerialExecutor()
    }

    let worker: ArchiveReadWorker

    init(worker: ArchiveReadWorker) {
        self.worker = worker
    }

    func read(_ entry: ArchiveReadDescriptor, path: String) throws -> Data {
        try worker.read(entry, path: path)
    }

    func extract(
        _ entry: ArchiveReadDescriptor,
        path: String,
        to destination: URL,
        durability: ArchiveDurability
    ) throws {
        try worker.extract(entry, path: path, to: destination, durability: durability)
    }

    func consume(
        _ entry: ArchiveReadDescriptor,
        path: String,
        consumer: @Sendable (Data) throws -> Void
    ) throws {
        try worker.consume(entry, path: path, consumer: consumer)
    }
}

/// High-performance archive reader providing concurrent positional reads, streaming decompression, and security validation.
public actor ArchiveReader {
    private nonisolated let executor = DispatchSerialQueue(label: "ZipMello.reader", qos: .utility)
    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        executor.asUnownedSerialExecutor()
    }

    private var index: [String: ArchiveReadDescriptor] = [:]
    private var members: [ArchiveMember] = []
    private var lanes: [ArchiveReadLane] = []
    private var nextLane = 0
    private var aliases: [String: String] = [:]
    private var ambiguousAliases: Set<String> = []
    private var aliasesReady = false
    private var worker: ArchiveReadWorker?
    private var inlineWorker: ArchiveReadWorker?
    private let limits: ArchiveLimits
    private let tuning: ArchiveTuning

    private init(limits: ArchiveLimits, tuning: ArchiveTuning) {
        self.limits = limits
        self.tuning = tuning
    }

    /// Opens an archive file at the specified file URL, verifying bounds and indexing the central directory.
    public static func open(
        _ url: URL,
        limits: ArchiveLimits = .init(),
        tuning: ArchiveTuning = .init()
    ) async throws -> ArchiveReader {
        try limits.validate()
        try tuning.validate()
        let reader = ArchiveReader(limits: limits, tuning: tuning)
        try await reader.load(url)
        return reader
    }

    private func load(_ url: URL) throws {
        try Task.checkCancellation()
        guard url.isFileURL else {
            throw ArchiveFailure.invalidSource(url.absoluteString)
        }
        let file = try ArchiveFile(url, bypassFileCache: tuning.bypassFileCache)
        guard file.bytes <= limits.maximumArchiveBytes else {
            throw ArchiveFailure.archiveTooLarge
        }
        try file.validateIdentity(at: url)
        let parser = try ZipCentralDirectoryParser.parse(input: .file(file))
        try loadIndex(parser, input: .file(file))
        try file.validateIdentity(at: url)
    }

    /// Opens an in-memory archive from a `Data` buffer without temporary file spooling.
    public static func open(
        data: Data,
        limits: ArchiveLimits = .init(),
        tuning: ArchiveTuning = .init()
    ) async throws -> ArchiveReader {
        try limits.validate()
        try tuning.validate()
        guard UInt64(data.count) <= limits.maximumArchiveBytes else {
            throw ArchiveFailure.archiveTooLarge
        }
        let reader = ArchiveReader(limits: limits, tuning: tuning)
        try await reader.load(data)
        return reader
    }

    private func load(_ data: Data) throws {
        try Task.checkCancellation()
        let parser = try ZipCentralDirectoryParser.parse(input: .bytes(data))
        try loadIndex(parser, input: .bytes(data))
    }

    private func loadIndex(_ parser: ZipCentralDirectoryParser, input: ArchiveInput) throws {
        let validated = try ValidatedArchiveIndex(parser: parser, input: input, bytes: input.count, limits: limits)
        index = validated.index
        members = validated.members
        let worker = ArchiveReadWorker(input: input, limits: limits, tuning: tuning)
        self.worker = worker
        if tuning.readConcurrency == 1 {
            inlineWorker = worker
        }
        lanes = (0..<tuning.readConcurrency).map { _ in
            ArchiveReadLane(worker: worker)
        }
    }

    /// Returns the complete list of member entries parsed from the archive central directory.
    public func listing() throws -> [ArchiveMember] {
        guard !lanes.isEmpty else {
            throw ArchiveFailure.closed
        }
        return members
    }

    /// Reads and decompresses the complete binary payload for an entry.
    public func read(_ path: String, lookup: ArchiveLookup = .exact) async throws -> Data {
        let (entry, lane) = try select(path, lookup: lookup)
        if let inlineWorker {
            return try inlineWorker.read(entry, path: path)
        }
        return try await lane.read(entry, path: path)
    }

    /// Extracts an entry directly to a destination file URL.
    public func extract(
        _ path: String,
        to destination: URL,
        lookup: ArchiveLookup = .exact,
        durability: ArchiveDurability = .synchronized
    ) async throws {
        let (entry, lane) = try select(path, lookup: lookup)
        if let inlineWorker {
            try inlineWorker.extract(entry, path: path, to: destination, durability: durability)
            return
        }
        try await lane.extract(entry, path: path, to: destination, durability: durability)
    }

    /// Streams decompressed chunks of an entry to a consumer closure.
    public func consume(
        _ path: String,
        lookup: ArchiveLookup = .exact,
        consumer: @Sendable (Data) throws -> Void
    ) async throws {
        let (entry, lane) = try select(path, lookup: lookup)
        if let inlineWorker {
            try inlineWorker.consume(entry, path: path, consumer: consumer)
            return
        }
        try await lane.consume(entry, path: path, consumer: consumer)
    }

    /// Verifies that the underlying archive file has not been replaced on disk.
    public func validateSource() throws {
        guard let worker else {
            throw ArchiveFailure.closed
        }
        try worker.validateIdentity()
    }

    /// Performs full streaming decompression and CRC32 verification across all non-directory archive members.
    public func validate(progress: ArchiveProgressHandler? = nil) throws {
        try Task.checkCancellation()
        guard let worker else {
            throw ArchiveFailure.closed
        }
        try worker.validateIdentity()

        let files = members.filter { !$0.isDirectory }
        let total = files.reduce(UInt64(0)) { $0 + $1.uncompressedBytes }
        var completed: UInt64 = 0

        progress?(.init(completedBytes: 0, totalBytes: total, completedEntries: 0, totalEntries: files.count))

        for (number, member) in files.enumerated() {
            guard let entry = index[member.path] else {
                throw ArchiveFailure.missingEntry(member.path)
            }
            var emitted: UInt64 = 0
            try worker.consume(entry, path: member.path) { chunk in
                emitted += UInt64(chunk.count)
                progress?(.init(
                    completedBytes: completed + emitted,
                    totalBytes: total,
                    completedEntries: number,
                    totalEntries: files.count
                ))
            }
            completed += member.uncompressedBytes
            progress?(.init(
                completedBytes: completed,
                totalBytes: total,
                completedEntries: number + 1,
                totalEntries: files.count
            ))
        }

        try worker.validateIdentity()
    }

    /// Returns metadata for a specific entry path.
    public func member(_ path: String, lookup: ArchiveLookup = .exact) throws -> ArchiveMember {
        let resolved = try resolve(path, lookup: lookup)
        if let entry = index[resolved] {
            return ArchiveMember(
                path: resolved,
                uncompressedBytes: entry.expandedBytes,
                compressedBytes: entry.compressedBytes,
                isDirectory: false
            )
        }
        guard let member = members.first(where: { $0.path == resolved }) else {
            throw ArchiveFailure.missingEntry(path)
        }
        return member
    }

    private func resolve(_ path: String, lookup: ArchiveLookup) throws -> String {
        guard !lanes.isEmpty else {
            throw ArchiveFailure.closed
        }
        if index[path] != nil {
            return path
        }
        if lookup == .exact {
            return path
        }

        if !aliasesReady {
            for member in members where !member.isDirectory {
                let canonical = try ArchivePath.canonical(member.path)
                var keys = [ArchivePath.alias(canonical)]
                if let decoded = canonical.removingPercentEncoding,
                   (try? ArchivePath.validate(decoded)) != nil {
                    keys.append(ArchivePath.alias(decoded))
                }
                for key in keys {
                    if let existing = aliases[key], existing != member.path {
                        ambiguousAliases.insert(key)
                    } else {
                        aliases[key] = member.path
                    }
                }
            }
            aliasesReady = true
        }

        let key = ArchivePath.alias(try ArchivePath.canonical(path))
        guard !ambiguousAliases.contains(key) else {
            throw ArchiveFailure.ambiguousEntry(path)
        }
        return aliases[key] ?? path
    }

    /// Extracts all entries into a destination directory using an atomic staging tree.
    /// Existing destinations are never overwritten. Each file extraction drains autoreleased memory.
    public func extractAll(to destination: URL, progress: ArchiveProgressHandler? = nil) throws {
        try Task.checkCancellation()
        guard let worker else {
            throw ArchiveFailure.closed
        }
        try worker.validateIdentity()
        let plan = try ArchiveTreePlan(members: members)
        let fm = FileManager.default

        guard destination.isFileURL else {
            throw ArchiveFailure.invalidSource(destination.absoluteString)
        }
        guard !fm.fileExists(atPath: destination.path) else {
            throw ArchiveFailure.destinationExists
        }

        let staging = destination.deletingLastPathComponent().appendingPathComponent(".tree-" + UUID().uuidString)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer {
            try? fm.removeItem(at: staging)
        }

        for path in plan.directories {
            try Task.checkCancellation()
            try fm.createDirectory(at: staging.appendingPathComponent(path), withIntermediateDirectories: false)
        }

        let total = plan.files.reduce(UInt64(0)) { $0 + $1.member.uncompressedBytes }
        var completed: UInt64 = 0
        progress?(.init(completedBytes: 0, totalBytes: total, completedEntries: 0, totalEntries: plan.files.count))

        for (number, item) in plan.files.enumerated() {
            try autoreleasepool {
                try Task.checkCancellation()
                guard let entry = index[item.member.path] else {
                    throw ArchiveFailure.missingEntry(item.member.path)
                }
                let url = staging.appendingPathComponent(item.path)
                let descriptor = try FileDescriptor.open(
                    url.path,
                    .writeOnly,
                    options: [.create, .exclusiveCreate, .noFollow],
                    permissions: .ownerReadWrite
                )
                do {
                    var emitted: UInt64 = 0
                    try worker.consume(entry, path: item.member.path) { chunk in
                        try descriptor.writeAll(chunk)
                        emitted += UInt64(chunk.count)
                        progress?(.init(
                            completedBytes: completed + emitted,
                            totalBytes: total,
                            completedEntries: number,
                            totalEntries: plan.files.count
                        ))
                    }
                    try descriptor.close()
                } catch {
                    try? descriptor.close()
                    throw error
                }
                completed += item.member.uncompressedBytes
                progress?(.init(
                    completedBytes: completed,
                    totalBytes: total,
                    completedEntries: number + 1,
                    totalEntries: plan.files.count
                ))
            }
        }

        try Task.checkCancellation()
        try worker.validateIdentity()
        try fm.moveItem(at: staging, to: destination)
    }

    private func select(_ path: String, lookup: ArchiveLookup) throws -> (ArchiveReadDescriptor, ArchiveReadLane) {
        try Task.checkCancellation()
        guard !lanes.isEmpty else {
            throw ArchiveFailure.closed
        }
        let resolved = try resolve(path, lookup: lookup)
        guard let entry = index[resolved] else {
            if members.contains(where: { $0.path == path }) {
                throw ArchiveFailure.unsupportedEntry(path)
            }
            throw ArchiveFailure.missingEntry(path)
        }
        let lane = lanes[nextLane]
        nextLane = (nextLane + 1) % lanes.count
        return (entry, lane)
    }

    /// Closes the archive reader, clearing index maps and terminating worker lanes.
    /// In-flight reads that were already dispatched retain their descriptor until completion.
    public func close() {
        worker = nil
        inlineWorker = nil
        lanes.removeAll()
        index.removeAll()
        members.removeAll()
        aliases.removeAll()
        ambiguousAliases.removeAll()
        aliasesReady = false
    }
}
