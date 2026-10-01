import Foundation
import Dispatch
import ZIPFoundation

/// Immutable byte-backed index for batch reads without actor hops between members.
/// Call from a bounded archive worker; initialization/extraction are synchronous.
public struct ArchiveMemoryReader: Sendable {
    private let validated: ValidatedArchiveIndex
    private let worker: ArchiveReadWorker
    private let lookup: ArchiveLookup
    public init(data: Data, limits: ArchiveLimits = .init(), tuning: ArchiveTuning = .init(), lookup: ArchiveLookup = .exact) throws {
        try limits.validate(); try tuning.validate(); try Task.checkCancellation()
        guard UInt64(data.count) <= limits.maximumArchiveBytes else { throw ArchiveFailure.archiveTooLarge }
        validated = try ValidatedArchiveIndex(Archive(data: data, accessMode: .read), bytes: UInt64(data.count), limits: limits)
        worker = ArchiveReadWorker(input: .bytes(data), limits: limits, tuning: tuning)
        self.lookup = lookup
    }
    public func listing() -> [ArchiveMember] { validated.members }
    public func read(_ path: String) throws -> Data {
        try Task.checkCancellation()
        var resolved = path
        if validated.index[path] == nil, lookup == .compatible {
            let key = ArchivePath.alias(try ArchivePath.canonical(path))
            var match: String?
            for member in validated.members where !member.isDirectory {
                let canonical = try ArchivePath.canonical(member.path)
                let decoded = canonical.removingPercentEncoding
                let decodedMatch = decoded.map { (try? ArchivePath.validate($0)) != nil && ArchivePath.alias($0) == key } ?? false
                if ArchivePath.alias(canonical) == key || decodedMatch {
                    guard match == nil else { throw ArchiveFailure.ambiguousEntry(path) }
                    match = member.path
                }
            }
            resolved = match ?? path
        }
        guard let entry = validated.index[resolved] else { throw ArchiveFailure.missingEntry(path) }
        return try worker.read(entry, path: resolved)
    }
}

/// Reusable dedicated executor for downloaded archive responses; one hop per request.
public actor ArchiveMemoryService {
    public static let shared = ArchiveMemoryService()
    private nonisolated let executor = DispatchSerialQueue(label: "ZipMello.memory", qos: .userInitiated)
    public nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
    public init() {}
    public func read(_ path: String, data: Data, limits: ArchiveLimits = .sourcePages,
                     lookup: ArchiveLookup = .compatible) throws -> Data {
        try ArchiveMemoryReader(data: data, limits: limits, lookup: lookup).read(path)
    }
}
