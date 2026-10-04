import Foundation
import ZipMello
import ZIPFoundation
import CryptoKit

/// Benchmark: In-Memory Page Extraction (50 pages).
///
/// Timed region:
/// - Measures extraction/decompression performance of in-memory ZIP payloads into materialized `Data`.
/// - Archive parsing and reader initialization (`ArchiveMemoryReader(data:)` and `Archive(data:)`)
///   occur OUTSIDE the timer so index construction overhead is not conflated with payload throughput.
/// - Both engines materialize full `Data` with 64 KB buffers and verify CRC.
/// - SHA-256 verification occurs strictly outside the timer in `validate()`.
public final class WorkloadMemory: HeadToHeadWorkload, @unchecked Sendable {
    public let name: String
    private let archiveURL: URL
    private var archiveData: Data = Data()
    private var targetPaths: [String] = []

    // Pre-constructed in-memory readers
    private var zipMelloReader: ArchiveMemoryReader?
    private var zfArchive: Archive?
    private var zfEntries: [String: Entry] = [:]

    private var lastZMBytes: Int = 0
    private var lastZFBytes: Int = 0

    public init(archiveURL: URL, name: String = "In-Memory Page Extraction (50 pages, stored)") {
        self.archiveURL = archiveURL
        self.name = name
    }

    public func prepare() async throws {
        let data = try Data(contentsOf: archiveURL)
        self.archiveData = data

        // Construct ZipMello in-memory reader outside the timer
        let zmReader = try ArchiveMemoryReader(data: data)
        self.zipMelloReader = zmReader

        let pages = zmReader.listing()
            .filter { $0.path.hasSuffix(".jpg") }
            .map { $0.path }
            .sorted(by: deterministicNaturalSort)
        self.targetPaths = Array(pages.prefix(50))

        // Construct ZIPFoundation in-memory archive outside the timer
        let archive = try Archive(data: data, accessMode: .read)
        self.zfArchive = archive
        var map: [String: Entry] = [:]
        for entry in archive {
            map[entry.path] = entry
        }
        self.zfEntries = map
    }

    public func runZipMello() async throws -> WorkloadRunResult {
        guard let reader = zipMelloReader else {
            throw NSError(domain: "WorkloadMemory", code: 1, userInfo: [NSLocalizedDescriptionKey: "ZipMello reader not prepared"])
        }

        let clock = ContinuousClock()
        let start = clock.now
        var totalBytes = 0

        for path in targetPaths {
            let data = try reader.read(path)
            totalBytes &+= data.count
            // 'data' goes out of scope and is immediately reclaimed
        }

        let elapsed = clock.now - start
        let durationSec = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18

        self.lastZMBytes = totalBytes
        return WorkloadRunResult(durationSeconds: durationSec, sinkMetric: totalBytes)
    }

    public func runZIPFoundation() async throws -> WorkloadRunResult {
        guard let archive = zfArchive else {
            throw NSError(domain: "WorkloadMemory", code: 2, userInfo: [NSLocalizedDescriptionKey: "ZIPFoundation archive not prepared"])
        }

        let clock = ContinuousClock()
        let start = clock.now
        var totalBytes = 0

        for path in targetPaths {
            guard let entry = zfEntries[path] else {
                throw NSError(domain: "WorkloadMemory", code: 3, userInfo: [NSLocalizedDescriptionKey: "Missing entry: \(path)"])
            }

            var data = Data()
            data.reserveCapacity(Int(entry.uncompressedSize))
            let checksum = try archive.extract(entry, bufferSize: 65536) { chunk in
                data.append(chunk)
            }
            guard checksum == entry.checksum else {
                throw NSError(domain: "WorkloadMemory", code: 4, userInfo: [NSLocalizedDescriptionKey: "CRC mismatch for \(path)"])
            }

            totalBytes &+= data.count
            // 'data' goes out of scope and is immediately reclaimed
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
                domain: "WorkloadMemory",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "Byte mismatch: ZipMello=\(lastZMBytes), ZIPFoundation=\(lastZFBytes)"]
            )
        }

        // Untimed separate verification pass
        guard let reader = zipMelloReader, let archive = zfArchive else { return }
        var zmHasher = SHA256()
        var zfHasher = SHA256()

        for path in targetPaths {
            let zmData = try reader.read(path)
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
                domain: "WorkloadMemory",
                code: 6,
                userInfo: [NSLocalizedDescriptionKey: "SHA-256 payload digest mismatch between ZipMello and ZIPFoundation"]
            )
        }
    }
}
