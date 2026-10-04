import Foundation
import Dispatch
import Synchronization

/// A reference-counted lease granting read access to an extracted file in the page store.
/// The underlying file is guaranteed to remain on disk as long as this lease is held.
public final class ArchiveFileLease: Sendable {
    public let url: URL
    private let id: UUID
    private let store: ArchivePageStore
    private let released = Mutex(false)

    fileprivate init(url: URL, id: UUID, store: ArchivePageStore) {
        self.url = url
        self.id = id
        self.store = store
    }

    /// Releases this lease, allowing the underlying file to be evicted if no other leases remain.
    public func release() async {
        let shouldRelease = released.withLock { isReleased in
            if isReleased {
                return false
            }
            isReleased = true
            return true
        }
        guard shouldRelease else {
            return
        }
        await store.release(id)
    }

    deinit {
        let shouldRelease = released.withLock { isReleased in
            if isReleased {
                return false
            }
            isReleased = true
            return true
        }
        guard shouldRelease else {
            return
        }
        let store = self.store
        let id = self.id
        Task {
            await store.release(id)
        }
    }
}

/// A lightweight session bound to a specific archive generation for leasing extracted page assets.
public struct ArchivePageSession: Sendable {
    fileprivate let url: URL
    fileprivate let identity: ArchiveFileIdentity
    fileprivate let store: ArchivePageStore

    /// Leases an extracted file from the session's bound archive.
    public func lease(_ path: String, lookup: ArchiveLookup = .compatible) async throws -> ArchiveFileLease {
        try await store.lease(path, from: url, identity: identity, lookup: lookup)
    }
}

/// Bounded extracted-file memoization store above the session pool.
///
/// Ensures that active leases are never evicted during cache pressure, coalesces in-flight
/// extraction requests for identical assets, and applies LRU eviction when memory/file count limits are reached.
public actor ArchivePageStore {
    private nonisolated let executor = DispatchSerialQueue(label: "ZipMello.pages", qos: .utility)
    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        executor.asUnownedSerialExecutor()
    }

    private struct Key: Hashable, Sendable {
        let url: URL
        let path: String
        let identity: ArchiveFileIdentity
    }

    private struct Cached {
        let key: Key
        let url: URL
        let bytes: UInt64
        var leases: Int = 0
        var lastUse: UInt64
        var retired: Bool = false
    }

    private struct Prepared: Sendable {
        let url: URL
        let bytes: UInt64
    }

    private struct Pending {
        let id: UUID
        let epoch: UInt64
        let task: Task<Prepared, Error>
    }

    private let directory: URL
    private let pool: ArchiveSessionPool
    private let maximumBytes: UInt64
    private let maximumFiles: Int
    private let maximumExtractions: Int

    private var entries: [UUID: Cached] = [:]
    private var keys: [Key: UUID] = [:]
    private var pending: [Key: Pending] = [:]
    private var reservations: [UUID: UInt64] = [:]
    private var waiters: [UUID: Int] = [:]
    private var leases: [UUID: UUID] = [:]
    private var tick: UInt64 = 0
    private var epoch: UInt64 = 0
    private var extractionCount: UInt64 = 0
    private var hitCount: UInt64 = 0
    private var evictionCount: UInt64 = 0
    private var inFlightExtractions: Int = 0
    private var permitWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var permitQueue: [UUID] = []
    private var queuedRequestCount: UInt64 = 0
    private var peakQueueDepthCount: Int = 0
    private var cancelledBeforeExtractionCount: UInt64 = 0

    /// Initializes a page store with byte and file bounds in a designated working directory.
    public init(
        directory: URL,
        maximumBytes: UInt64 = 512 * 1_024 * 1_024,
        maximumFiles: Int = 256,
        maximumExtractions: Int = 4,
        limits: ArchiveLimits = .init(),
        tuning: ArchiveTuning = .pagePrefetch
    ) throws {
        guard directory.isFileURL, maximumBytes > 0, maximumFiles > 0, (1...32).contains(maximumExtractions) else {
            throw ArchiveFailure.invalidLimits
        }
        self.directory = directory.appendingPathComponent("ZipMello-" + UUID().uuidString, isDirectory: true)
        self.maximumBytes = maximumBytes
        self.maximumFiles = maximumFiles
        self.maximumExtractions = maximumExtractions
        self.pool = try ArchiveSessionPool(maximumSessions: maximumExtractions, limits: limits, tuning: tuning)
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Creates an immutable session bound to the specified archive URL.
    public func session(for archive: URL) throws -> ArchivePageSession {
        try Task.checkCancellation()
        let url = archive.standardizedFileURL
        return ArchivePageSession(url: url, identity: try ArchiveFileIdentity(url), store: self)
    }

    /// Acquires a lease for an extracted file from the specified archive.
    public func lease(_ path: String, from archive: URL, lookup: ArchiveLookup = .compatible) async throws -> ArchiveFileLease {
        try Task.checkCancellation()
        let url = archive.standardizedFileURL
        return try await lease(path, from: url, identity: ArchiveFileIdentity(url), lookup: lookup)
    }

    fileprivate func acquireExtractionPermit() async throws {
        try Task.checkCancellation()
        if inFlightExtractions < maximumExtractions {
            inFlightExtractions += 1
            return
        }

        queuedRequestCount += 1
        let ticket = UUID()
        permitQueue.append(ticket)
        peakQueueDepthCount = max(peakQueueDepthCount, permitQueue.count)

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                permitWaiters[ticket] = continuation
            }
        } onCancel: {
            Task { [self] in
                await self.cancelPermitWait(ticket: ticket)
            }
        }
    }

    fileprivate func cancelPermitWait(ticket: UUID) {
        if let idx = permitQueue.firstIndex(of: ticket) {
            permitQueue.remove(at: idx)
            cancelledBeforeExtractionCount += 1
        }
        if let continuation = permitWaiters.removeValue(forKey: ticket) {
            continuation.resume(throwing: CancellationError())
        }
    }

    fileprivate func releaseExtractionPermit() {
        while !permitQueue.isEmpty {
            let nextTicket = permitQueue.removeFirst()
            if let continuation = permitWaiters.removeValue(forKey: nextTicket) {
                continuation.resume()
                return
            }
        }
        inFlightExtractions = max(0, inFlightExtractions - 1)
    }

    fileprivate func lease(
        _ path: String,
        from url: URL,
        identity: ArchiveFileIdentity,
        lookup: ArchiveLookup
    ) async throws -> ArchiveFileLease {
        try Task.checkCancellation()
        let key = Key(url: url, path: path, identity: identity)

        if let id = keys[key], let cached = entries[id], FileManager.default.fileExists(atPath: cached.url.path) {
            hitCount += 1
            return acquire(id)
        }

        if let id = keys.removeValue(forKey: key), var cached = entries[id] {
            cached.retired = true
            entries[id] = cached
            if cached.leases == 0 {
                evict(id)
            }
        }

        let item: Pending
        if let existing = pending[key] {
            item = existing
        } else {
            let id = UUID()
            let currentEpoch = epoch
            let pool = pool
            let directory = directory

            let task = Task { [self] in
                try await self.acquireExtractionPermit()
                var permitHeld = true
                do {
                    try Task.checkCancellation()
                    let member = try await pool.member(path, from: url, lookup: lookup)
                    guard !member.isDirectory else {
                        throw ArchiveFailure.unsupportedEntry(path)
                    }
                    try Task.checkCancellation()
                    try self.reserve(member.uncompressedBytes, id: id, epoch: currentEpoch)
                    let ext = URL(fileURLWithPath: member.path).pathExtension
                    let output = directory.appendingPathComponent(id.uuidString).appendingPathExtension(ext)
                    do {
                        try await pool.extract(member.path, from: url, to: output, durability: .buffered)
                        try Task.checkCancellation()
                        guard try ArchiveFileIdentity(url) == key.identity else {
                            throw ArchiveFailure.invalidSource("Archive changed during extraction")
                        }
                        self.releaseExtractionPermit()
                        permitHeld = false
                        return Prepared(url: output, bytes: member.uncompressedBytes)
                    } catch {
                        try? FileManager.default.removeItem(at: output)
                        throw error
                    }
                } catch {
                    if permitHeld {
                        self.releaseExtractionPermit()
                    }
                    throw error
                }
            }
            item = Pending(id: id, epoch: currentEpoch, task: task)
            pending[key] = item
            extractionCount += 1
        }

        waiters[item.id, default: 0] += 1
        defer {
            let remaining = (waiters[item.id] ?? 1) - 1
            waiters[item.id] = remaining == 0 ? nil : remaining
            if remaining == 0, let cached = entries[item.id], cached.retired && cached.leases == 0 {
                evict(item.id)
            }
        }

        do {
            let file = try await item.task.value
            guard item.epoch == epoch else {
                try? FileManager.default.removeItem(at: file.url)
                throw CancellationError()
            }
            if entries[item.id] == nil {
                reservations[item.id] = nil
                entries[item.id] = Cached(
                    key: key,
                    url: file.url,
                    bytes: file.bytes,
                    leases: 0,
                    lastUse: tick,
                    retired: false
                )
                keys[key] = item.id
            }
            if pending[key]?.id == item.id {
                pending[key] = nil
            }
            try Task.checkCancellation()
            return acquire(item.id)
        } catch {
            reservations[item.id] = nil
            if pending[key]?.id == item.id {
                pending[key] = nil
            }
            throw error
        }
    }

    private func calculateAllocatedBytes() -> UInt64 {
        entries.values.reduce(UInt64(0)) { $0 + $1.bytes } + reservations.values.reduce(UInt64(0), +)
    }

    fileprivate func reserve(_ bytes: UInt64, id: UUID, epoch: UInt64) throws {
        guard epoch == self.epoch else {
            throw CancellationError()
        }
        guard bytes <= maximumBytes else {
            throw ArchiveFailure.cacheCapacityExceeded
        }

        while calculateAllocatedBytes() > maximumBytes - bytes || entries.count + reservations.count >= maximumFiles {
            let evictable = entries.filter { $0.value.leases == 0 && waiters[$0.key, default: 0] == 0 }
            guard let victim = evictable.min(by: { $0.value.lastUse < $1.value.lastUse })?.key else {
                throw ArchiveFailure.cacheCapacityExceeded
            }
            evict(victim)
        }
        reservations[id] = bytes
    }

    private func acquire(_ id: UUID) -> ArchiveFileLease {
        tick &+= 1
        let token = UUID()
        entries[id]?.leases += 1
        entries[id]?.lastUse = tick
        leases[token] = id
        return ArchiveFileLease(url: entries[id]!.url, id: token, store: self)
    }

    fileprivate func release(_ token: UUID) {
        guard let id = leases.removeValue(forKey: token), var cached = entries[id] else {
            return
        }
        cached.leases -= 1
        entries[id] = cached
        if cached.retired && cached.leases == 0 {
            evict(id)
        }
    }

    private func evict(_ id: UUID) {
        guard let cached = entries.removeValue(forKey: id) else {
            return
        }
        evictionCount += 1
        if keys[cached.key] == id {
            keys[cached.key] = nil
        }
        try? FileManager.default.removeItem(at: cached.url)
    }

    /// Retires the cache and cancels pending extractions; active leases remain valid until released.
    public func removeAll() async {
        epoch &+= 1
        keys.removeAll()
        for item in pending.values {
            item.task.cancel()
        }
        pending.removeAll()

        for continuation in permitWaiters.values {
            continuation.resume(throwing: CancellationError())
        }
        permitWaiters.removeAll()
        permitQueue.removeAll()
        inFlightExtractions = 0

        for id in Array(entries.keys) {
            entries[id]?.retired = true
            if entries[id]?.leases == 0 {
                evict(id)
            }
        }
        await pool.removeAll()
    }

    /// Statistics on active leases, cached files, extraction operations, hits, and evictions.
    public struct Statistics: Sendable {
        public let files: Int
        public let bytes: UInt64
        public let activeLeases: Int
        public let extractions: UInt64
        public let hits: UInt64
        public let evictions: UInt64
        public let queuedRequests: UInt64
        public let peakQueueDepth: Int
        public let cancelledBeforeExtraction: UInt64

        public init(
            files: Int,
            bytes: UInt64,
            activeLeases: Int,
            extractions: UInt64,
            hits: UInt64 = 0,
            evictions: UInt64 = 0,
            queuedRequests: UInt64 = 0,
            peakQueueDepth: Int = 0,
            cancelledBeforeExtraction: UInt64 = 0
        ) {
            self.files = files
            self.bytes = bytes
            self.activeLeases = activeLeases
            self.extractions = extractions
            self.hits = hits
            self.evictions = evictions
            self.queuedRequests = queuedRequests
            self.peakQueueDepth = peakQueueDepth
            self.cancelledBeforeExtraction = cancelledBeforeExtraction
        }
    }

    /// Returns a telemetry snapshot of page store usage.
    public func statistics() -> Statistics {
        Statistics(
            files: entries.count,
            bytes: calculateAllocatedBytes(),
            activeLeases: leases.count,
            extractions: extractionCount,
            hits: hitCount,
            evictions: evictionCount,
            queuedRequests: queuedRequestCount,
            peakQueueDepth: peakQueueDepthCount,
            cancelledBeforeExtraction: cancelledBeforeExtractionCount
        )
    }
}
