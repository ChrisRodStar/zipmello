import Foundation
import Dispatch
import Darwin

/// Pool entries are owned by the pool; callers get operations, not a closeable reader.
/// Eviction releases the pool's ownership, while in-flight calls retain their reader.
public actor ArchiveSessionPool {
    private nonisolated let executor = DispatchSerialQueue(label: "ZipMello.sessions", qos: .utility)
    public nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
    private struct Identity: Equatable, Sendable {
        let device: Int32
        let inode: UInt64
        let bytes: Int64
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let changedSeconds: Int
        let changedNanoseconds: Int
    }
    private struct Session {
        let identity: Identity
        let reader: ArchiveReader
        let weight: UInt64
        var lastUse: UInt64
    }
    private struct Opening {
        let id: UUID
        let identity: Identity
        let task: Task<ArchiveReader, Error>
    }
    private let limits: ArchiveLimits
    private let tuning: ArchiveTuning
    private let maximumSessions: Int
    private let maximumIndexBytes: UInt64
    private var sessions: [URL: Session] = [:]
    private var openings: [URL: Opening] = [:]
    private var tick: UInt64 = 0
    private var openCount: UInt64 = 0
    private var hitCount: UInt64 = 0

    public init(maximumSessions: Int = 4, maximumIndexBytes: UInt64 = 16 * 1_024 * 1_024,
                limits: ArchiveLimits = .init(), tuning: ArchiveTuning = .init()) throws {
        try limits.validate(); try tuning.validate()
        guard (1...32).contains(maximumSessions), maximumIndexBytes > 0 else { throw ArchiveFailure.invalidLimits }
        self.maximumSessions = maximumSessions; self.maximumIndexBytes = maximumIndexBytes
        self.limits = limits; self.tuning = tuning
    }
    public func read(_ path: String, from url: URL, lookup: ArchiveLookup = .exact) async throws -> Data {
        let reader = try await session(url)
        return try await reader.read(path, lookup: lookup)
    }
    public func extract(_ path: String, from url: URL, to destination: URL, lookup: ArchiveLookup = .exact, durability: ArchiveDurability = .synchronized) async throws {
        let reader = try await session(url)
        try await reader.extract(path, to: destination, lookup: lookup, durability: durability)
    }
    public func listing(_ url: URL) async throws -> [ArchiveMember] {
        let reader = try await session(url)
        return try await reader.listing()
    }
    public func member(_ path: String, from url: URL, lookup: ArchiveLookup = .exact) async throws -> ArchiveMember {
        let reader = try await session(url)
        return try await reader.member(path, lookup: lookup)
    }
    public func validate(_ url: URL, progress: ArchiveProgressHandler? = nil) async throws {
        let reader = try await session(url)
        try await reader.validate(progress: progress)
    }
    public struct Statistics: Sendable {
        public let cachedSessions: Int
        public let estimatedIndexBytes: UInt64
        public let opens: UInt64
        public let hits: UInt64
    }
    public func statistics() -> Statistics {
        .init(cachedSessions: sessions.count, estimatedIndexBytes: sessions.values.reduce(0) { $0 + $1.weight },
              opens: openCount, hits: hitCount)
    }
    public func removeAll() {
        sessions.removeAll()
        for item in openings.values { item.task.cancel() }
        openings.removeAll()
    }
    private func session(_ input: URL) async throws -> ArchiveReader {
        try Task.checkCancellation()
        let url = input.standardizedFileURL
        let identity = try fingerprint(url)
        tick &+= 1
        if var session = sessions[url], session.identity == identity {
            session.lastUse = tick; sessions[url] = session; hitCount += 1
            return session.reader
        }
        sessions[url] = nil
        let opening: Opening
        if let existing = openings[url], existing.identity == identity { opening = existing }
        else {
            // Bound distinct in-flight opens as well as cached descriptors.
            guard openings.count < maximumSessions else {
                throw ArchiveFailure.sessionCapacityExceeded
            }
            let limits = limits, tuning = tuning
            opening = .init(id: UUID(), identity: identity,
                task: Task { try await ArchiveReader.open(url, limits: limits, tuning: tuning) })
            openings[url] = opening
            openCount += 1
        }
        do {
            let reader = try await opening.task.value
            try Task.checkCancellation()
            guard try fingerprint(url) == identity else { throw ArchiveFailure.invalidSource("Archive changed during open") }
            if openings[url]?.id == opening.id {
                let members = try await reader.listing()
                guard openings[url]?.id == opening.id else { return reader }
                openings[url] = nil
                // Conservative accounting model, not an allocator measurement.
                let weight = members.reduce(UInt64(256)) { $0 + UInt64(256 + 2 * $1.path.utf8.count) }
                if weight <= maximumIndexBytes {
                    while sessions.count >= maximumSessions || sessions.values.reduce(UInt64(0), { $0 + $1.weight }) + weight > maximumIndexBytes {
                        guard let victim = sessions.min(by: { $0.value.lastUse < $1.value.lastUse })?.key else { break }
                        sessions[victim] = nil
                    }
                    sessions[url] = .init(identity: identity, reader: reader, weight: weight, lastUse: tick)
                }
            }
            return reader
        } catch {
            if openings[url]?.id == opening.id { openings[url] = nil }
            throw error
        }
    }
    private func fingerprint(_ url: URL) throws -> Identity {
        guard url.isFileURL else { throw ArchiveFailure.invalidSource(url.absoluteString) }
        var value = stat()
        guard lstat(url.path, &value) == 0, value.st_mode & S_IFMT == S_IFREG else {
            throw ArchiveFailure.invalidSource(url.path)
        }
        return .init(device: value.st_dev, inode: value.st_ino, bytes: value.st_size,
            modifiedSeconds: value.st_mtimespec.tv_sec, modifiedNanoseconds: value.st_mtimespec.tv_nsec,
            changedSeconds: value.st_ctimespec.tv_sec, changedNanoseconds: value.st_ctimespec.tv_nsec)
    }
}
