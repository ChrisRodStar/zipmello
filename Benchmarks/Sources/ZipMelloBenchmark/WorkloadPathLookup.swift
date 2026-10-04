import Foundation
import ZipMello
import ZIPFoundation

/// Benchmark: Path Lookup by Name (80 lookups: Stock Archive[path] vs Pre-indexed Dictionary).
///
/// Demonstrates the lookup complexity difference:
/// - ZipMello builds a path index during archive open, providing average O(1) hash map lookups.
/// - Stock ZIPFoundation `archive[path]` performs a linear O(N) scan through its entry list for every call.
/// - This benchmark measures only entry resolution (no payload decompression).
public final class WorkloadPathLookup: HeadToHeadWorkload, @unchecked Sendable {
    public let name = "Path Lookup by Name (80 lookups, stock vs indexed)"
    private let archiveURL: URL
    private let seed: UInt64
    private var randomOrder: [String] = []

    private var zipMelloReader: ArchiveReader?
    private var zfArchive: Archive?

    public init(archiveURL: URL, seed: UInt64 = 0x123456789ABCDEF) {
        self.archiveURL = archiveURL
        self.seed = seed
    }

    public func prepare() async throws {
        let zmReader = try await ArchiveReader.open(archiveURL)
        let listing = try await zmReader.listing()
        self.zipMelloReader = zmReader

        let paths = listing.map(\.path).sorted(by: deterministicNaturalSort)
        var prng = DeterministicPRNG(seed: seed)
        self.randomOrder = prng.shuffled(paths)

        let arch = try Archive(url: archiveURL, accessMode: .read)
        self.zfArchive = arch
    }

    deinit {
        let r = zipMelloReader
        Task {
            await r?.close()
        }
    }

    public func runZipMello() async throws -> WorkloadRunResult {
        guard let reader = zipMelloReader else {
            throw NSError(domain: "WorkloadPathLookup", code: 1, userInfo: [NSLocalizedDescriptionKey: "ZipMello reader not prepared"])
        }

        let clock = ContinuousClock()
        let start = clock.now
        var matches = 0

        for path in randomOrder {
            if (try? await reader.member(path)) != nil {
                matches &+= 1
            }
        }

        let elapsed = clock.now - start
        let durationSec = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        return WorkloadRunResult(durationSeconds: durationSec, sinkMetric: matches)
    }

    public func runZIPFoundation() async throws -> WorkloadRunResult {
        guard let archive = zfArchive else {
            throw NSError(domain: "WorkloadPathLookup", code: 2, userInfo: [NSLocalizedDescriptionKey: "ZIPFoundation archive not prepared"])
        }

        let clock = ContinuousClock()
        let start = clock.now
        var matches = 0

        for path in randomOrder {
            // Stock ZIPFoundation linear scan: archive[path] traverses all entries
            if archive[path] != nil {
                matches &+= 1
            }
        }

        let elapsed = clock.now - start
        let durationSec = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        return WorkloadRunResult(durationSeconds: durationSec, sinkMetric: matches)
    }

    public func validate() async throws {
        // Lookups are read-only metadata checks
    }
}
