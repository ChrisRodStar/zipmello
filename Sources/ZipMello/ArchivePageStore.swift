import Foundation
import Dispatch
import Synchronization

/// A file remains present while this lease is held, including after store clearing.
/// Release explicitly for prompt cleanup; deinit supplies a fallback.
public final class ArchiveFileLease: Sendable {
    public let url: URL
    private let id: UUID
    private let store: ArchivePageStore
    private let released = Mutex(false)
    fileprivate init(url: URL, id: UUID, store: ArchivePageStore) { self.url = url; self.id = id; self.store = store }
    public func release() async {
        guard released.withLock({ value in if value { return false }; value = true; return true }) else { return }
        await store.release(id)
    }
    deinit {
        guard released.withLock({ value in if value { return false }; value = true; return true }) else { return }
        let store = store, id = id
        Task { await store.release(id) }
    }
}

/// Snapshot of one immutable chapter generation. Reopen after replacing the chapter archive.
public struct ArchivePageSession: Sendable {
    fileprivate let url: URL
    fileprivate let identity: ArchiveFileIdentity
    fileprivate let store: ArchivePageStore
    public func lease(_ path: String, lookup: ArchiveLookup = .compatible) async throws -> ArchiveFileLease {
        try await store.lease(path, from: url, identity: identity, lookup: lookup)
    }
}

/// Bounded extracted-file memoization above the index pool. Storage limits include active
/// leases and in-flight reservations; active pages are never evicted to satisfy a request.
public actor ArchivePageStore {
    private nonisolated let executor = DispatchSerialQueue(label: "ZipMello.pages", qos: .utility)
    public nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
    private struct Key: Hashable, Sendable { let url: URL; let path: String; let identity: ArchiveFileIdentity }
    private struct Cached {
        let key: Key; let url: URL; let bytes: UInt64
        var leases = 0; var lastUse: UInt64; var retired = false
    }
    private struct Prepared: Sendable { let url: URL; let bytes: UInt64 }
    private struct Pending { let id: UUID; let epoch: UInt64; let task: Task<Prepared, Error> }
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

    public init(directory: URL, maximumBytes: UInt64 = 512 * 1_024 * 1_024,
                maximumFiles: Int = 256, maximumExtractions: Int = 4,
                limits: ArchiveLimits = .init(), tuning: ArchiveTuning = .pagePrefetch) throws {
        guard directory.isFileURL, maximumBytes > 0, maximumFiles > 0, (1...32).contains(maximumExtractions) else {
            throw ArchiveFailure.invalidLimits
        }
        self.directory = directory.appendingPathComponent("ZipMello-" + UUID().uuidString, isDirectory: true)
        self.maximumBytes = maximumBytes; self.maximumFiles = maximumFiles; self.maximumExtractions = maximumExtractions
        pool = try ArchiveSessionPool(maximumSessions: maximumExtractions, limits: limits, tuning: tuning)
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    deinit { try? FileManager.default.removeItem(at: directory) }

    public func session(for archive: URL) throws -> ArchivePageSession {
        try Task.checkCancellation()
        let url = archive.standardizedFileURL
        return .init(url: url, identity: try ArchiveFileIdentity(url), store: self)
    }

    public func lease(_ path: String, from archive: URL, lookup: ArchiveLookup = .compatible) async throws -> ArchiveFileLease {
        try Task.checkCancellation()
        let url = archive.standardizedFileURL
        return try await lease(path, from: url, identity: ArchiveFileIdentity(url), lookup: lookup)
    }
    fileprivate func lease(_ path: String, from url: URL, identity: ArchiveFileIdentity, lookup: ArchiveLookup) async throws -> ArchiveFileLease {
        try Task.checkCancellation()
        let key = Key(url: url, path: path, identity: identity)
        if let id = keys[key], let cached = entries[id], FileManager.default.fileExists(atPath: cached.url.path) {
            return acquire(id)
        }
        if let id = keys.removeValue(forKey: key), var cached = entries[id] {
            cached.retired = true; entries[id] = cached
            if cached.leases == 0 { evict(id) }
        }
        let item: Pending
        if let existing = pending[key] { item = existing }
        else {
            guard pending.count < maximumExtractions else { throw ArchiveFailure.cacheCapacityExceeded }
            let id = UUID(), currentEpoch = epoch, pool = pool, directory = directory
            let task = Task { [self] in
                let member = try await pool.member(path, from: url, lookup: lookup)
                guard !member.isDirectory else { throw ArchiveFailure.unsupportedEntry(path) }
                try Task.checkCancellation()
                try reserve(member.uncompressedBytes, id: id, epoch: currentEpoch)
                let output = directory.appendingPathComponent(id.uuidString).appendingPathExtension(URL(fileURLWithPath: member.path).pathExtension)
                do {
                    try await pool.extract(member.path, from: url, to: output, durability: .buffered)
                    try Task.checkCancellation()
                    guard try ArchiveFileIdentity(url) == key.identity else { throw ArchiveFailure.invalidSource("Archive changed during extraction") }
                    return Prepared(url: output, bytes: member.uncompressedBytes)
                } catch { try? FileManager.default.removeItem(at: output); throw error }
            }
            item = Pending(id: id, epoch: currentEpoch, task: task)
            pending[key] = item
            extractionCount += 1
        }
        waiters[item.id, default: 0] += 1
        defer {
            let remaining = (waiters[item.id] ?? 1) - 1
            waiters[item.id] = remaining == 0 ? nil : remaining
            if remaining == 0, let cached = entries[item.id], cached.retired, cached.leases == 0 { evict(item.id) }
        }
        do {
            let file = try await item.task.value
            guard item.epoch == epoch else {
                try? FileManager.default.removeItem(at: file.url)
                throw CancellationError()
            }
            if entries[item.id] == nil {
                // The first waiter publishes; later waiters share the same extracted file.
                reservations[item.id] = nil
                entries[item.id] = Cached(key: key, url: file.url, bytes: file.bytes, lastUse: tick)
                keys[key] = item.id
            }
            if pending[key]?.id == item.id { pending[key] = nil }
            try Task.checkCancellation()
            return acquire(item.id)
        } catch {
            reservations[item.id] = nil
            if pending[key]?.id == item.id { pending[key] = nil }
            throw error
        }
    }

    private func reserve(_ bytes: UInt64, id: UUID, epoch: UInt64) throws {
        guard epoch == self.epoch else { throw CancellationError() }
        guard bytes <= maximumBytes else { throw ArchiveFailure.cacheCapacityExceeded }
        func usedBytes() -> UInt64 { entries.values.reduce(0) { $0 + $1.bytes } + reservations.values.reduce(0, +) }
        while usedBytes() > maximumBytes - bytes || entries.count + reservations.count >= maximumFiles {
            guard let victim = entries.filter({ $0.value.leases == 0 && waiters[$0.key, default: 0] == 0 }).min(by: { $0.value.lastUse < $1.value.lastUse })?.key else {
                throw ArchiveFailure.cacheCapacityExceeded
            }
            evict(victim)
        }
        reservations[id] = bytes
    }
    private func acquire(_ id: UUID) -> ArchiveFileLease {
        tick &+= 1
        let token = UUID()
        entries[id]!.leases += 1; entries[id]!.lastUse = tick
        leases[token] = id
        return ArchiveFileLease(url: entries[id]!.url, id: token, store: self)
    }
    fileprivate func release(_ token: UUID) {
        guard let id = leases.removeValue(forKey: token), var cached = entries[id] else { return }
        cached.leases -= 1; entries[id] = cached
        if cached.retired && cached.leases == 0 { evict(id) }
    }
    private func evict(_ id: UUID) {
        guard let cached = entries.removeValue(forKey: id) else { return }
        if keys[cached.key] == id { keys[cached.key] = nil }
        try? FileManager.default.removeItem(at: cached.url)
    }
    /// Retires the cache and cancels pending work; active leases remain readable until release.
    public func removeAll() async {
        epoch &+= 1
        keys.removeAll()
        for item in pending.values { item.task.cancel() }
        pending.removeAll()
        for id in Array(entries.keys) {
            entries[id]!.retired = true
            if entries[id]!.leases == 0 { evict(id) }
        }
        await pool.removeAll()
    }
    public struct Statistics: Sendable {
        public let files: Int; public let bytes: UInt64; public let activeLeases: Int; public let extractions: UInt64
    }
    public func statistics() -> Statistics {
        .init(files: entries.count, bytes: entries.values.reduce(0) { $0 + $1.bytes } + reservations.values.reduce(0, +),
              activeLeases: leases.count, extractions: extractionCount)
    }
}
