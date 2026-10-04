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
        let task: Task<Void, Never>
        var waiters: [UUID: CheckedContinuation<ArchiveFileLease, Error>]
    }

    private let directory: URL
    private let pool: ArchiveSessionPool
    private let maximumBytes: UInt64
    private let maximumFiles: Int
    private let maximumExtractions: Int

    private var entries: [UUID: Cached] = [:]
    private var keys: [Key: UUID] = [:]
    private var pending: [Key: Pending] = [:]
    private var extractionTasks: [UUID: Task<Void, Never>] = [:]
    private var reservations: [UUID: UInt64] = [:]
    private var resolvedKeys: [Key: Key] = [:]
    private var allocatedBytes: UInt64 = 0
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
        let request = Key(url: url, path: path, identity: identity)
        var key = lookup == .compatible ? resolvedKeys[request] ?? request : request
        if let lease = cachedLease(key) { return lease }

        let currentEpoch = epoch
        var member: ArchiveMember?
        if pending[key] == nil {
            let resolved = try await resolveMember(path, from: url, lookup: lookup, epoch: currentEpoch)
            try Task.checkCancellation()
            guard currentEpoch == epoch else { throw CancellationError() }
            guard identity.matches(url: url) else {
                throw ArchiveFailure.invalidSource("Archive changed before extraction")
            }
            guard !resolved.isDirectory else { throw ArchiveFailure.unsupportedEntry(path) }
            key = Key(url: url, path: resolved.path, identity: identity)
            if lookup == .compatible {
                if resolvedKeys.count >= maximumFiles { resolvedKeys.removeAll(keepingCapacity: true) }
                resolvedKeys[request] = key
            }
            if let lease = cachedLease(key) { return lease }
            member = resolved
        }

        let resolvedKey = key
        let resolvedMember = member
        let ticket = UUID()
        let lease = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                if var item = pending[resolvedKey] {
                    item.waiters[ticket] = continuation
                    pending[resolvedKey] = item
                    return
                }
                // New work always has metadata resolved under this caller's lookup policy.
                guard let member = resolvedMember else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let id = UUID()
                let task = Task { [self] in
                    do {
                        let file = try await prepare(member, key: resolvedKey, id: id, epoch: currentEpoch)
                        finish(resolvedKey, id: id, epoch: currentEpoch, result: .success(file))
                    } catch {
                        finish(resolvedKey, id: id, epoch: currentEpoch, result: .failure(error))
                    }
                }
                pending[resolvedKey] = Pending(id: id, epoch: currentEpoch, task: task, waiters: [ticket: continuation])
                extractionTasks[id] = task
                extractionCount += 1
            }
        } onCancel: {
            Task { await self.cancelLeaseWaiter(resolvedKey, ticket: ticket) }
        }
        if Task.isCancelled {
            await lease.release()
            throw CancellationError()
        }
        return lease
    }

    private func cachedLease(_ key: Key) -> ArchiveFileLease? {
        guard let id = keys[key], var cached = entries[id] else { return nil }
        if FileManager.default.fileExists(atPath: cached.url.path) {
            hitCount += 1
            return acquire(id)
        }
        keys[key] = nil
        cached.retired = true
        entries[id] = cached
        if cached.leases == 0 { evict(id) }
        return nil
    }

    private func resolveMember(_ path: String, from url: URL, lookup: ArchiveLookup, epoch: UInt64) async throws -> ArchiveMember {
        // Opening metadata also uses a permit so requests across many archives remain bounded.
        try await acquireExtractionPermit()
        defer { releaseExtractionPermit() }
        try Task.checkCancellation()
        guard epoch == self.epoch else { throw CancellationError() }
        return try await pool.member(path, from: url, lookup: lookup)
    }

    private func prepare(_ member: ArchiveMember, key: Key, id: UUID, epoch: UInt64) async throws -> Prepared {
        try await acquireExtractionPermit()
        defer { releaseExtractionPermit() }
        try Task.checkCancellation()
        try reserve(member.uncompressedBytes, id: id, epoch: epoch)
        let ext = URL(fileURLWithPath: member.path).pathExtension
        let output = directory.appendingPathComponent(id.uuidString).appendingPathExtension(ext)
        do {
            try await pool.extract(member.path, from: key.url, to: output, durability: .buffered)
            try Task.checkCancellation()
            guard key.identity.matches(url: key.url) else {
                throw ArchiveFailure.invalidSource("Archive changed during extraction")
            }
            return Prepared(url: output, bytes: member.uncompressedBytes)
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }

    private func cancelLeaseWaiter(_ key: Key, ticket: UUID) {
        guard var item = pending[key], let waiter = item.waiters.removeValue(forKey: ticket) else { return }
        waiter.resume(throwing: CancellationError())
        if item.waiters.isEmpty {
            item.task.cancel()
            pending[key] = nil
            // The task retains its reservation until it has stopped writing.
        } else {
            pending[key] = item
        }
    }

    private func finish(_ key: Key, id: UUID, epoch: UInt64, result: Result<Prepared, Error>) {
        extractionTasks[id] = nil
        guard let item = pending[key], item.id == id, epoch == self.epoch else {
            releaseReservation(id)
            if case .success(let file) = result { try? FileManager.default.removeItem(at: file.url) }
            return
        }
        pending[key] = nil
        switch result {
        case .success(let file):
            // Transfer the reservation to a cached entry without changing allocatedBytes.
            reservations[id] = nil
            entries[id] = Cached(key: key, url: file.url, bytes: file.bytes, lastUse: tick, retired: false)
            keys[key] = id
            for waiter in item.waiters.values { waiter.resume(returning: acquire(id)) }
        case .failure(let error):
            releaseReservation(id)
            for waiter in item.waiters.values { waiter.resume(throwing: error) }
        }
    }

    private func releaseReservation(_ id: UUID) {
        if let bytes = reservations.removeValue(forKey: id) { allocatedBytes -= bytes }
    }

    private func reserve(_ bytes: UInt64, id: UUID, epoch: UInt64) throws {
        guard epoch == self.epoch else { throw CancellationError() }
        guard bytes <= maximumBytes else { throw ArchiveFailure.cacheCapacityExceeded }
        while allocatedBytes > maximumBytes - bytes || entries.count + reservations.count >= maximumFiles {
            let victim = entries.lazy.filter { $0.value.leases == 0 }
                .min(by: { $0.value.lastUse < $1.value.lastUse })?.key
            guard let victim else { throw ArchiveFailure.cacheCapacityExceeded }
            evict(victim)
        }
        reservations[id] = bytes
        allocatedBytes += bytes
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
        allocatedBytes -= cached.bytes
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
        resolvedKeys.removeAll()
        let tasks = Array(extractionTasks.values)
        for task in tasks { task.cancel() }
        for item in pending.values {
            item.task.cancel()
            for waiter in item.waiters.values { waiter.resume(throwing: CancellationError()) }
        }
        pending.removeAll()
        cancelledBeforeExtractionCount += UInt64(permitQueue.count)
        for waiter in permitWaiters.values { waiter.resume(throwing: CancellationError()) }
        permitWaiters.removeAll()
        permitQueue.removeAll()

        // Active tasks still own permits. They release them while draining, including across epochs.
        for id in Array(entries.keys) {
            entries[id]?.retired = true
            if entries[id]?.leases == 0 { evict(id) }
        }
        await pool.removeAll()
        for task in tasks { await task.value }
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
            bytes: allocatedBytes,
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
