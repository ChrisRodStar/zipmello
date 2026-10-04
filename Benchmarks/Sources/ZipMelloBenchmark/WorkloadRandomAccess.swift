import Foundation
import ZipMello
import ZIPFoundation
import CryptoKit

/// Benchmark: Random-Access Page Reads (80 pages).
///
/// Timed region:
/// - Pure random page extraction into materialized `Data` across 80 pages.
/// - Archive opening and central-directory indexing occur OUTSIDE the timed region.
/// - ZIPFoundation entries are pre-indexed into `[String: Entry]` outside the timer to eliminate its
///   stock linear-scan lookup overhead and compare pure extraction engines fairly.
/// - Both engines materialize full `Data` with 64 KB buffers and verify CRC32.
/// - SHA-256 verification happens strictly outside the timer in `validate()`.
public final class WorkloadRandomAccess: HeadToHeadWorkload, @unchecked Sendable {
    public let name: String
    private let archiveURL: URL
    private let seed: UInt64
    private var randomOrder: [String] = []

    // Pre-warmed archive readers constructed outside the timer
    private var zipMelloReader: ArchiveReader?
    private var zfArchive: Archive?
    private var zfEntries: [String: Entry] = [:]

    private var lastZMBytes: Int = 0
    private var lastZFBytes: Int = 0

    public init(archiveURL: URL, seed: UInt64 = 0x123456789ABCDEF, name: String = "Random-Access Page Reads (80 pages, pre-indexed)") {
        self.archiveURL = archiveURL
        self.seed = seed
        self.name = name
    }

    public func prepare() async throws {
        // Open ZipMello reader outside the timer
        let zmReader = try await ArchiveReader.open(archiveURL)
        let listing = try await zmReader.listing()
        self.zipMelloReader = zmReader

        let imagePaths = listing
            .filter { $0.path.hasSuffix(".jpg") }
            .map { $0.path }
            .sorted(by: deterministicNaturalSort)

        // Open ZIPFoundation archive and pre-index entries into a hash map outside the timer
        let archive = try Archive(url: archiveURL, accessMode: .read)
        self.zfArchive = archive
        var entryMap: [String: Entry] = [:]
        for entry in archive {
            entryMap[entry.path] = entry
        }
        self.zfEntries = entryMap

        // Generate deterministic random permutation using SplitMix64
        var prng = DeterministicPRNG(seed: seed)
        self.randomOrder = prng.shuffled(imagePaths)
    }

    deinit {
        let r = zipMelloReader
        Task {
            await r?.close()
        }
    }

    public func runZipMello() async throws -> WorkloadRunResult {
        guard let reader = zipMelloReader else {
            throw NSError(domain: "WorkloadRandomAccess", code: 1, userInfo: [NSLocalizedDescriptionKey: "ZipMello reader not prepared"])
        }

        let clock = ContinuousClock()
        let start = clock.now
        var totalBytes = 0

        for path in randomOrder {
            // Materialize full Data (ZipMello validates CRC32 internally)
            let data = try await reader.read(path)
            totalBytes &+= data.count
            // 'data' goes out of scope here and is immediately reclaimed
        }

        let elapsed = clock.now - start
        let durationSec = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18

        self.lastZMBytes = totalBytes
        return WorkloadRunResult(durationSeconds: durationSec, sinkMetric: totalBytes)
    }

    public func runZIPFoundation() async throws -> WorkloadRunResult {
        guard let archive = zfArchive else {
            throw NSError(domain: "WorkloadRandomAccess", code: 2, userInfo: [NSLocalizedDescriptionKey: "ZIPFoundation archive not prepared"])
        }

        let clock = ContinuousClock()
        let start = clock.now
        var totalBytes = 0

        for path in randomOrder {
            guard let entry = zfEntries[path] else {
                throw NSError(domain: "WorkloadRandomAccess", code: 3, userInfo: [NSLocalizedDescriptionKey: "Missing entry: \(path)"])
            }

            // Materialize full Data with capacity reservation and 64 KB buffer
            var data = Data()
            data.reserveCapacity(Int(entry.uncompressedSize))
            let checksum = try archive.extract(entry, bufferSize: 65536) { chunk in
                data.append(chunk)
            }
            guard checksum == entry.checksum else {
                throw NSError(domain: "WorkloadRandomAccess", code: 4, userInfo: [NSLocalizedDescriptionKey: "Checksum mismatch for \(path)"])
            }

            totalBytes &+= data.count
            // 'data' goes out of scope here and is immediately reclaimed
        }

        let elapsed = clock.now - start
        let durationSec = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18

        self.lastZFBytes = totalBytes
        return WorkloadRunResult(durationSeconds: durationSec, sinkMetric: totalBytes)
    }

    public func validate() async throws {
        guard lastZMBytes > 0, lastZFBytes > 0 else { return }
        guard lastZMBytes == lastZFBytes else {
            throw NSError(
                domain: "WorkloadRandomAccess",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "Byte count mismatch: ZipMello=\(lastZMBytes), ZIPFoundation=\(lastZFBytes)"]
            )
        }

        // Perform independent SHA-256 verification pass completely outside the timer
        guard let reader = zipMelloReader, let archive = zfArchive else { return }
        var zmHasher = SHA256()
        var zfHasher = SHA256()

        for path in randomOrder {
            let zmData = try await reader.read(path)
            zmHasher.update(data: zmData)

            guard let entry = zfEntries[path] else { continue }
            var zfData = Data()
            zfData.reserveCapacity(Int(entry.uncompressedSize))
            _ = try archive.extract(entry, bufferSize: 65536) { zfData.append($0) }
            zfHasher.update(data: zfData)
        }

        let zmDigest = zmHasher.finalize().map { String(format: "%02x", $0) }.joined()
        let zfDigest = zfHasher.finalize().map { String(format: "%02x", $0) }.joined()

        guard zmDigest == zfDigest else {
            throw NSError(
                domain: "WorkloadRandomAccess",
                code: 6,
                userInfo: [NSLocalizedDescriptionKey: "SHA-256 payload digest mismatch between ZipMello and ZIPFoundation"]
            )
        }
    }
}
