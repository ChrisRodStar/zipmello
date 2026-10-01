import Foundation
import Dispatch
import Darwin

/// Manages a bounded pool of open `ArchiveReader` instances to minimize file open and index parsing overhead.
///
/// Archive sessions are owned and managed by the pool. Callers issue operations directly against the pool,
/// which automatically coalesces in-flight opening requests and evicts the least recently used sessions
/// when session or index memory budgets are exceeded.
public actor ArchiveSessionPool {
    private nonisolated let executor = DispatchSerialQueue(label: "ZipMello.sessions", qos: .utility)
    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        executor.asUnownedSerialExecutor()
    }

    private struct Session {
        let identity: ArchiveFileIdentity
        let reader: ArchiveReader
        let weight: UInt64
        var lastUse: UInt64
    }

    private struct Opening {
        let id: UUID
        let identity: ArchiveFileIdentity
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

    /// Initializes a session pool with bounds on concurrent sessions and estimated index memory.
    public init(
        maximumSessions: Int = 4,
        maximumIndexBytes: UInt64 = 16 * 1_024 * 1_024,
        limits: ArchiveLimits = .init(),
        tuning: ArchiveTuning = .init()
    ) throws {
        try limits.validate()
        try tuning.validate()
        guard (1...32).contains(maximumSessions), maximumIndexBytes > 0 else {
            throw ArchiveFailure.invalidLimits
        }
        self.maximumSessions = maximumSessions
        self.maximumIndexBytes = maximumIndexBytes
        self.limits = limits
        self.tuning = tuning
    }

    /// Reads an entry's uncompressed data from an archive at the specified URL.
    public func read(_ path: String, from url: URL, lookup: ArchiveLookup = .exact) async throws -> Data {
        let reader = try await session(url)
        return try await reader.read(path, lookup: lookup)
    }

    /// Extracts an entry from an archive directly to a destination file URL.
    public func extract(
        _ path: String,
        from url: URL,
        to destination: URL,
        lookup: ArchiveLookup = .exact,
        durability: ArchiveDurability = .synchronized
    ) async throws {
        let reader = try await session(url)
        try await reader.extract(path, to: destination, lookup: lookup, durability: durability)
    }

    /// Returns the central directory member listing for the archive at the specified URL.
    public func listing(_ url: URL) async throws -> [ArchiveMember] {
        let reader = try await session(url)
        return try await reader.listing()
    }

    /// Returns the metadata for a specific entry in the archive at the specified URL.
    public func member(_ path: String, from url: URL, lookup: ArchiveLookup = .exact) async throws -> ArchiveMember {
        let reader = try await session(url)
        return try await reader.member(path, lookup: lookup)
    }

    /// Validates CRC32 checksums for every entry in the archive.
    public func validate(_ url: URL, progress: ArchiveProgressHandler? = nil) async throws {
        let reader = try await session(url)
        try await reader.validate(progress: progress)
    }

    /// Runtime telemetry and cache hit statistics for the session pool.
    public struct Statistics: Sendable {
        public let cachedSessions: Int
        public let estimatedIndexBytes: UInt64
        public let opens: UInt64
        public let hits: UInt64
    }

    /// Returns a snapshot of current session cache statistics.
    public func statistics() -> Statistics {
        let totalWeight = sessions.values.reduce(UInt64(0)) { $0 + $1.weight }
        return Statistics(
            cachedSessions: sessions.count,
            estimatedIndexBytes: totalWeight,
            opens: openCount,
            hits: hitCount
        )
    }

    /// Evicts all cached sessions and cancels all in-flight archive opens.
    public func removeAll() {
        sessions.removeAll()
        for item in openings.values {
            item.task.cancel()
        }
        openings.removeAll()
    }

    /// Retrieves an existing valid reader or opens a new session with in-flight request coalescing.
    private func session(_ input: URL) async throws -> ArchiveReader {
        try Task.checkCancellation()
        let url = input.standardizedFileURL
        let identity = try ArchiveFileIdentity(url)
        tick &+= 1

        if var session = sessions[url], session.identity == identity {
            session.lastUse = tick
            sessions[url] = session
            hitCount += 1
            return session.reader
        }

        sessions[url] = nil

        let opening: Opening
        if let existing = openings[url], existing.identity == identity {
            opening = existing
        } else {
            guard openings.count < maximumSessions else {
                throw ArchiveFailure.sessionCapacityExceeded
            }
            let limits = limits
            let tuning = tuning
            opening = Opening(
                id: UUID(),
                identity: identity,
                task: Task {
                    try await ArchiveReader.open(url, limits: limits, tuning: tuning)
                }
            )
            openings[url] = opening
            openCount += 1
        }

        do {
            let reader = try await opening.task.value
            try Task.checkCancellation()

            guard identity.matches(url: url) else {
                throw ArchiveFailure.invalidSource("Archive changed during open")
            }

            if openings[url]?.id == opening.id {
                let members = try await reader.listing()
                guard openings[url]?.id == opening.id else {
                    return reader
                }
                openings[url] = nil

                // Estimate index memory weight: 256 bytes per entry + path UTF-8 bytes
                let weight = members.reduce(UInt64(256)) { $0 + UInt64(256 + 2 * $1.path.utf8.count) }
                if weight <= maximumIndexBytes {
                    while sessions.count >= maximumSessions ||
                            sessions.values.reduce(UInt64(0), { $0 + $1.weight }) + weight > maximumIndexBytes {
                        guard let victim = sessions.min(by: { $0.value.lastUse < $1.value.lastUse })?.key else {
                            break
                        }
                        sessions[victim] = nil
                    }
                    sessions[url] = Session(
                        identity: identity,
                        reader: reader,
                        weight: weight,
                        lastUse: tick
                    )
                }
            }
            return reader
        } catch {
            if openings[url]?.id == opening.id {
                openings[url] = nil
            }
            throw error
        }
    }
}
