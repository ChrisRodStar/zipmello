import Foundation
import Dispatch

/// Immutable in-memory reader designed for synchronous, low-overhead member extraction.
///
/// `ArchiveMemoryReader` operates directly over a pre-loaded `Data` buffer without requiring
/// a backing file on disk or actor hops between member reads. It is ideally suited for network-downloaded
/// ZIP archives, embedded application resources, and batch comic page decoding.
public struct ArchiveMemoryReader: Sendable {
    private let validated: ValidatedArchiveIndex
    private let worker: ArchiveReadWorker
    private let aliases: ArchiveAliasIndex?

    /// Initializes an in-memory archive reader by validating the central directory.
    ///
    /// - Parameters:
    ///   - data: In-memory byte buffer containing the complete ZIP archive.
    ///   - limits: Resource constraints governing maximum file sizes and member counts.
    ///   - tuning: Buffer size and decompression settings.
    ///   - lookup: Member lookup strategy (exact match or forgiving normalized path aliases).
    public init(
        data: Data,
        limits: ArchiveLimits = .init(),
        tuning: ArchiveTuning = .init(),
        lookup: ArchiveLookup = .exact
    ) throws {
        try limits.validate()
        try tuning.validate()
        try Task.checkCancellation()

        guard UInt64(data.count) <= limits.maximumArchiveBytes else {
            throw ArchiveFailure.archiveTooLarge
        }

        let parser = try ZipCentralDirectoryParser.parse(input: .bytes(data), limits: limits)
        validated = try ValidatedArchiveIndex(
            parser: parser,
            input: .bytes(data),
            bytes: UInt64(data.count),
            limits: limits
        )
        worker = ArchiveReadWorker(input: .bytes(data), limits: limits, tuning: tuning)
        aliases = lookup == .compatible ? try ArchiveAliasIndex(members: validated.members) : nil
    }

    /// Returns the verified manifest of entries contained within the in-memory archive.
    public func listing() -> [ArchiveMember] {
        validated.members
    }

    /// Synchronously reads and decompresses an archive entry by path.
    ///
    /// - Parameter path: Archive member path, matching either exact central directory naming
    ///   or compatible alias conventions when `lookup` is `.compatible`.
    /// - Returns: Complete uncompressed bytes for the requested member.
    public func read(_ path: String) throws -> Data {
        try Task.checkCancellation()

        let resolvedPath = validated.index[path] != nil ? path : try aliases?.resolve(path) ?? path

        guard let entry = validated.index[resolvedPath] else {
            throw ArchiveFailure.missingEntry(path)
        }
        return try worker.read(entry, path: resolvedPath)
    }
}

/// Dedicated serial actor service for safely dispatching in-memory archive decompression requests.
///
/// `ArchiveMemoryService` limits concurrency overhead when multiple tasks extract pages from
/// downloaded archives simultaneously.
public actor ArchiveMemoryService {
    public static let shared = ArchiveMemoryService()

    private nonisolated let executor = DispatchSerialQueue(label: "ZipMello.memory", qos: .userInitiated)
    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        executor.asUnownedSerialExecutor()
    }

    public init() {}

    /// Extracts an entry from an in-memory ZIP buffer with one actor hop.
    ///
    /// - Parameters:
    ///   - path: Entry path to decompress.
    ///   - data: In-memory byte buffer of the archive.
    ///   - limits: Security constraints.
    ///   - lookup: Member lookup strategy.
    /// - Returns: Decompressed entry data.
    public func read(
        _ path: String,
        data: Data,
        limits: ArchiveLimits = .sourcePages,
        lookup: ArchiveLookup = .compatible
    ) throws -> Data {
        try ArchiveMemoryReader(data: data, limits: limits, lookup: lookup).read(path)
    }
}
