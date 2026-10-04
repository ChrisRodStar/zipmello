import Foundation
import ZipMello
import ZipMelloConsumers
import ZIPFoundation
import CryptoKit

/// Benchmark: Library Discovery (Open + Inspect + Cover Extraction + ComicInfo Parsing).
///
/// Timed region:
/// - Represents a comic reader indexing a newly scanned archive file on disk.
/// - Archive opening and central directory parsing ARE included inside the timer because opening/indexing
///   is an integral part of discovery.
/// - Both engines route through a single, shared benchmark-local discovery adapter that executes
///   the exact same deterministic cover selection (using explicit POSIX natural sort) and ComicInfo.xml
///   decoding via `ComicInfoCodec.decode`. Archive inspection is the only independent variable.
public final class WorkloadDiscovery: HeadToHeadWorkload, @unchecked Sendable {
    public let name = "Library Discovery (Open + Cover + ComicInfo)"
    private let archiveURL: URL

    // Verification sinks
    private var lastZMCoverSize: Int = 0
    private var lastZFCoverSize: Int = 0

    public init(archiveURL: URL) {
        self.archiveURL = archiveURL
    }

    public func prepare() async throws {
        // Smoke test archive existence
        let reader = try await ArchiveReader.open(archiveURL)
        let listing = try await reader.listing()
        guard listing.contains(where: { $0.path.hasSuffix(".jpg") }) else {
            await reader.close()
            throw NSError(domain: "WorkloadDiscovery", code: 1, userInfo: [NSLocalizedDescriptionKey: "No pages found"])
        }
        await reader.close()
    }

    public func runZipMello() async throws -> WorkloadRunResult {
        let clock = ContinuousClock()
        let start = clock.now

        // 1. Open archive and index central directory
        let reader = try await ArchiveReader.open(archiveURL)
        let listing = try await reader.listing()
        let paths = listing.map(\.path)

        // 2. Shared discovery adapter: cover detection, extraction, and ComicInfo parsing
        let discovery = try await executeComicDiscovery(paths: paths) { path in
            try await reader.read(path)
        }

        await reader.close()

        let elapsed = clock.now - start
        let durationSec = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18

        self.lastZMCoverSize = discovery.coverSize
        let metric = discovery.coverSize &+ (discovery.hasComicInfo ? 1 : 0) &+ paths.count
        return WorkloadRunResult(durationSeconds: durationSec, sinkMetric: metric)
    }

    public func runZIPFoundation() async throws -> WorkloadRunResult {
        let clock = ContinuousClock()
        let start = clock.now

        // 1. Open archive and index central directory
        let archive = try Archive(url: archiveURL, accessMode: .read)
        var entryMap: [String: Entry] = [:]
        for entry in archive {
            entryMap[entry.path] = entry
        }
        let paths = Array(entryMap.keys)

        // 2. Shared discovery adapter: cover detection, extraction, and ComicInfo parsing
        let discovery = try await executeComicDiscovery(paths: paths) { path in
            guard let entry = entryMap[path] else {
                throw NSError(domain: "WorkloadDiscovery", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing entry: \(path)"])
            }
            var data = Data()
            data.reserveCapacity(Int(entry.uncompressedSize))
            let checksum = try archive.extract(entry, bufferSize: 65536) { chunk in
                data.append(chunk)
            }
            guard checksum == entry.checksum else {
                throw NSError(domain: "WorkloadDiscovery", code: 3, userInfo: [NSLocalizedDescriptionKey: "CRC mismatch for \(path)"])
            }
            return data
        }

        let elapsed = clock.now - start
        let durationSec = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18

        self.lastZFCoverSize = discovery.coverSize
        let metric = discovery.coverSize &+ (discovery.hasComicInfo ? 1 : 0) &+ paths.count
        return WorkloadRunResult(durationSeconds: durationSec, sinkMetric: metric)
    }

    public func validate() async throws {
        guard lastZMCoverSize > 0, lastZFCoverSize > 0 else { return }
        guard lastZMCoverSize == lastZFCoverSize else {
            throw NSError(
                domain: "WorkloadDiscovery",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Cover size mismatch: ZipMello=\(lastZMCoverSize), ZIPFoundation=\(lastZFCoverSize)"]
            )
        }

        // Untimed separate verification pass for cover digest
        let reader = try await ArchiveReader.open(archiveURL)
        let listing = try await reader.listing()
        let paths = listing.map(\.path)
        let imagePaths = paths
            .filter { path in
                let lower = path.lowercased()
                return lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg") || lower.hasSuffix(".png") || lower.hasSuffix(".webp")
            }
            .sorted(by: deterministicNaturalSort)

        guard let firstImage = imagePaths.first else {
            await reader.close()
            return
        }

        let zmCoverData = try await reader.read(firstImage)
        await reader.close()

        let archive = try Archive(url: archiveURL, accessMode: .read)
        guard let zfEntry = archive[firstImage] else {
            throw NSError(domain: "WorkloadDiscovery", code: 5, userInfo: [NSLocalizedDescriptionKey: "Missing entry in ZF: \(firstImage)"])
        }
        var zfCoverData = Data()
        zfCoverData.reserveCapacity(Int(zfEntry.uncompressedSize))
        _ = try archive.extract(zfEntry, bufferSize: 65536) { zfCoverData.append($0) }

        let zmDigest = SHA256.hash(data: zmCoverData).map { String(format: "%02x", $0) }.joined()
        let zfDigest = SHA256.hash(data: zfCoverData).map { String(format: "%02x", $0) }.joined()

        guard zmDigest == zfDigest else {
            throw NSError(
                domain: "WorkloadDiscovery",
                code: 6,
                userInfo: [NSLocalizedDescriptionKey: "Cover SHA-256 mismatch between ZipMello and ZIPFoundation"]
            )
        }
    }

    /// Shared adapter ensuring both engines execute identical sorting, cover detection, and ComicInfo parsing.
    private func executeComicDiscovery(
        paths: [String],
        read: (String) async throws -> Data
    ) async throws -> (coverSize: Int, hasComicInfo: Bool) {
        let imagePaths = paths
            .filter { path in
                let lower = path.lowercased()
                return lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg") || lower.hasSuffix(".png") || lower.hasSuffix(".webp")
            }
            .sorted(by: deterministicNaturalSort)

        var coverSize = 0
        if let firstImage = imagePaths.first {
            let coverData = try await read(firstImage)
            coverSize = coverData.count
        }

        var hasComicInfo = false
        if paths.contains("ComicInfo.xml") {
            let xmlData = try await read("ComicInfo.xml")
            if (try? ComicInfoCodec.decode(xmlData)) != nil {
                hasComicInfo = true
            }
        }

        return (coverSize, hasComicInfo)
    }
}
