import Foundation
import ZipMello
import ZIPFoundation
import CryptoKit

/// Thread-safe worker wrapping one independent ZIPFoundation handle and pre-indexed directory.
private actor ZFArchiveWorker {
    private let archive: Archive
    private let entries: [String: Entry]

    init(url: URL) throws {
        let arch = try Archive(url: url, accessMode: .read)
        self.archive = arch
        var map: [String: Entry] = [:]
        for entry in arch {
            map[entry.path] = entry
        }
        self.entries = map
    }

    func readEntry(_ path: String) throws -> (bytes: Int, data: Data) {
        guard let entry = entries[path] else {
            throw NSError(domain: "WorkloadConcurrent", code: 1, userInfo: [NSLocalizedDescriptionKey: "Entry not found: \(path)"])
        }
        var data = Data()
        data.reserveCapacity(Int(entry.uncompressedSize))
        let checksum = try archive.extract(entry, bufferSize: 65536) { chunk in
            data.append(chunk)
        }
        guard checksum == entry.checksum else {
            throw NSError(domain: "WorkloadConcurrent", code: 2, userInfo: [NSLocalizedDescriptionKey: "CRC mismatch for \(path)"])
        }
        return (data.count, data)
    }
}

/// Benchmark: Concurrent Prefetching (32 reads).
///
/// Timed region:
/// - Measures contention and concurrent throughput when 32 requests are issued simultaneously.
/// - Tasks are created outside the timer and wait behind a shared ConcurrencyGate.
/// - The timer starts at the exact moment the gate releases all 32 tasks together.
/// - ZipMello is explicitly configured with `ArchiveTuning.pagePrefetch` (4 read lanes).
/// - ZIPFoundation is given a competitive multi-handle baseline using a pool of 4 independent Archive instances.
/// - Both engines materialize full `Data` with 64 KB decompression buffers and verify CRC.
public final class WorkloadConcurrent: HeadToHeadWorkload, @unchecked Sendable {
    public let name = "Concurrent Prefetching (32 reads, 4 lanes vs 4 handles)"
    private let archiveURL: URL
    private var prefetchPaths: [String] = []

    // Pre-opened readers
    private var zipMelloReader: ArchiveReader?
    private var zfWorkers: [ZFArchiveWorker] = []

    // Validation sinks
    private var lastZMSHA256: String = ""
    private var lastZFSHA256: String = ""
    private var lastZMBytes: Int = 0
    private var lastZFBytes: Int = 0

    public init(archiveURL: URL) {
        self.archiveURL = archiveURL
    }

    public func prepare() async throws {
        // Open ZipMello with 4 concurrent read lanes
        let zmReader = try await ArchiveReader.open(archiveURL, tuning: .pagePrefetch)
        let listing = try await zmReader.listing()
        self.zipMelloReader = zmReader

        let allPages = listing
            .filter { $0.path.hasSuffix(".jpg") }
            .map { $0.path }
            .sorted(by: deterministicNaturalSort)

        // Select 32 distinct pages distributed evenly across the archive
        let strideVal = max(1, allPages.count / 32)
        self.prefetchPaths = (0..<32).map { allPages[($0 * strideVal) % allPages.count] }

        // Construct 4 independent ZIPFoundation handles for a competitive multi-threaded baseline
        var workers: [ZFArchiveWorker] = []
        for _ in 0..<4 {
            let worker = try ZFArchiveWorker(url: archiveURL)
            workers.append(worker)
        }
        self.zfWorkers = workers
    }

    deinit {
        let r = zipMelloReader
        Task {
            await r?.close()
        }
    }

    public func runZipMello() async throws -> WorkloadRunResult {
        guard let reader = zipMelloReader else {
            throw NSError(domain: "WorkloadConcurrent", code: 1, userInfo: [NSLocalizedDescriptionKey: "ZipMello reader not prepared"])
        }

        let paths = self.prefetchPaths
        let count = paths.count
        let gate = ConcurrencyGate(count: count)

        // Spawn tasks that synchronize at the common barrier
        let tasks: [Task<(bytes: Int, data: Data), Error>] = paths.map { path in
            Task {
                await gate.wait()
                let data = try await reader.read(path)
                return (data.count, data)
            }
        }

        let clock = ContinuousClock()
        let start = clock.now
        // Trip the barrier to release all 32 tasks simultaneously
        await gate.releaseWhenReady()

        var totalBytes = 0
        var hasher = SHA256()
        for t in tasks {
            let res = try await t.value
            totalBytes &+= res.bytes
            hasher.update(data: res.data)
        }

        let elapsed = clock.now - start
        let durationSec = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18

        self.lastZMBytes = totalBytes
        self.lastZMSHA256 = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return WorkloadRunResult(durationSeconds: durationSec, sinkMetric: totalBytes)
    }

    public func runZIPFoundation() async throws -> WorkloadRunResult {
        guard self.zfWorkers.count == 4 else {
            throw NSError(domain: "WorkloadConcurrent", code: 2, userInfo: [NSLocalizedDescriptionKey: "ZF workers not prepared"])
        }

        let paths = self.prefetchPaths
        let count = paths.count
        let gate = ConcurrencyGate(count: count)
        let workers = self.zfWorkers

        // Spawn tasks distributed round-robin across the 4 independent Archive handles
        var tasks: [Task<(bytes: Int, data: Data), Error>] = []
        for i in 0..<count {
            let path = paths[i]
            let worker = workers[i % 4]
            tasks.append(Task {
                await gate.wait()
                return try await worker.readEntry(path)
            })
        }

        let clock = ContinuousClock()
        let start = clock.now
        // Trip the barrier to release all 32 tasks simultaneously
        await gate.releaseWhenReady()

        var totalBytes = 0
        var hasher = SHA256()
        for t in tasks {
            let res = try await t.value
            totalBytes &+= res.bytes
            hasher.update(data: res.data)
        }

        let elapsed = clock.now - start
        let durationSec = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18

        self.lastZFBytes = totalBytes
        self.lastZFSHA256 = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return WorkloadRunResult(durationSeconds: durationSec, sinkMetric: totalBytes)
    }

    public func validate() async throws {
        guard lastZMBytes > 0, lastZFBytes > 0 else { return }
        guard lastZMBytes == lastZFBytes else {
            throw NSError(
                domain: "WorkloadConcurrent",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Byte mismatch: ZipMello=\(lastZMBytes), ZIPFoundation=\(lastZFBytes)"]
            )
        }
        guard lastZMSHA256 == lastZFSHA256 else {
            throw NSError(
                domain: "WorkloadConcurrent",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "SHA-256 payload digest mismatch between ZipMello and ZIPFoundation"]
            )
        }
    }
}
