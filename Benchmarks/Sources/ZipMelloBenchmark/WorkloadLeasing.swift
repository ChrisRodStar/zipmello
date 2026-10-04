import Foundation
import ZipMello

public struct LeasingResult: Sendable, Codable {
    public let stepsTraversed: Int
    public let peakConcurrentLeases: Int
    public let cacheHits: UInt64
    public let cacheMisses: UInt64
    public let evictions: UInt64
    public let peakCachedBytes: UInt64
    public let peakDiskFootprintBytes: UInt64
    public let hitLatency: MeasurementStats
    public let missLatency: MeasurementStats
    public let totalTraversalSec: Double

    public var peakCachedMB: Double {
        Double(peakCachedBytes) / (1024.0 * 1024.0)
    }

    public var peakDiskFootprintMB: Double {
        Double(peakDiskFootprintBytes) / (1024.0 * 1024.0)
    }
}

/// Benchmark: Continuous Scroll Viewport Leasing (ArchivePageStore Bounded Cache).
///
/// Methodology:
/// - Simulates a continuous vertical manga reader navigating an 80-page chapter.
/// - Active viewport retains 6 concurrent pages.
/// - Realistic traversal pattern: forward scrolling (0 -> 35), small 4-page backtrack (35 -> 31 -> 40),
///   second backtrack (50 -> 47 -> 74), and a partial reverse scroll (74 -> 55).
/// - Only newly visible pages entering the viewport are acquired; pages scrolling off-screen are released.
/// - Configured with `maximumExtractions: 6` to match the 6-page viewport concurrency.
/// - Enforces bounded cache limits (`maxFiles: 24`, `maxBytes: 6 MB`) so eviction policies are actively exercised.
/// - Measures and reports Cache Hit latency separately from Cache Miss (disk extraction) latency.
/// - Queries physical filesystem disk footprint separately from logical cached bytes.
/// - Guarantees fresh directory and session state per sample, with all leases released before cleanup.
public final class WorkloadLeasing: @unchecked Sendable {
    private let archiveURL: URL
    private let cacheDir: URL

    public init(archiveURL: URL, cacheDir: URL) {
        self.archiveURL = archiveURL
        self.cacheDir = cacheDir
    }

    public func run(
        budgetBytes: UInt64 = 6 * 1024 * 1024,
        maxFiles: Int = 24
    ) async throws -> LeasingResult {
        let fm = FileManager.default
        let staging = cacheDir.appendingPathComponent("lease-bench-" + UUID().uuidString)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        let store = try ArchivePageStore(
            directory: staging,
            maximumBytes: budgetBytes,
            maximumFiles: maxFiles,
            maximumExtractions: 6,
            tuning: .pagePrefetch
        )

        let session = try await store.session(for: archiveURL)

        let reader = try await ArchiveReader.open(archiveURL)
        let listing = try await reader.listing()
        await reader.close()

        let pages = listing
            .filter { $0.path.hasSuffix(".jpg") }
            .map { $0.path }
            .sorted(by: deterministicNaturalSort)

        guard pages.count >= 80 else {
            throw NSError(domain: "WorkloadLeasing", code: 1, userInfo: [NSLocalizedDescriptionKey: "Insufficient pages: \(pages.count)"])
        }

        // Construct realistic viewport step sequence:
        // Window size: 6 pages [topIndex ..< topIndex + 6]
        var viewportWindowStarts: [Int] = []

        // 1. Forward scroll 0 -> 35
        for i in 0...35 { viewportWindowStarts.append(i) }
        // 2. Backtrack 4 pages: 35 -> 31 -> 40
        for i in (31...34).reversed() { viewportWindowStarts.append(i) }
        for i in 32...40 { viewportWindowStarts.append(i) }
        // 3. Forward scroll to 50, backtrack to 47, forward to 74 (last window is 74..<80)
        for i in 41...50 { viewportWindowStarts.append(i) }
        for i in (47...49).reversed() { viewportWindowStarts.append(i) }
        for i in 48...74 { viewportWindowStarts.append(i) }
        // 4. Partial reverse scroll 74 down to 55
        for i in (55...73).reversed() { viewportWindowStarts.append(i) }

        var activeLeases: [Int: ArchiveFileLease] = [:]
        var peakConcurrent = 0
        var hitLatencies: [Double] = []
        var missLatencies: [Double] = []
        var peakDiskBytes: UInt64 = 0
        var peakCachedBytes: UInt64 = 0

        let clock = ContinuousClock()
        let traversalStart = clock.now

        for windowStart in viewportWindowStarts {
            let targetIndices = Set(windowStart..<(windowStart + 6))

            // 1. Release leases that have scrolled off-screen
            let exiting = activeLeases.keys.filter { !targetIndices.contains($0) }
            for pageIndex in exiting {
                if let lease = activeLeases.removeValue(forKey: pageIndex) {
                    await lease.release()
                }
            }

            // 2. Acquire leases for pages entering the window
            let entering = targetIndices.subtracting(activeLeases.keys).sorted()
            for pageIndex in entering {
                let statsBefore = await store.statistics()
                let pagePath = pages[pageIndex]

                let start = clock.now
                let lease = try await session.lease(pagePath)
                let elapsed = clock.now - start
                let elapsedSec = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18

                let statsAfter = await store.statistics()
                if statsAfter.hits > statsBefore.hits {
                    hitLatencies.append(elapsedSec)
                } else {
                    missLatencies.append(elapsedSec)
                }

                activeLeases[pageIndex] = lease
            }

            peakConcurrent = max(peakConcurrent, activeLeases.count)

            // 3. Track physical disk usage vs logical cached bytes
            let stats = await store.statistics()
            peakCachedBytes = max(peakCachedBytes, stats.bytes)

            if let contents = try? fm.subpathsOfDirectory(atPath: staging.path) {
                var currentPhysicalBytes: UInt64 = 0
                for sub in contents {
                    let fullPath = staging.appendingPathComponent(sub)
                    if let attrs = try? fm.attributesOfItem(atPath: fullPath.path),
                       let size = attrs[.size] as? UInt64 {
                        currentPhysicalBytes += size
                    }
                }
                peakDiskBytes = max(peakDiskBytes, currentPhysicalBytes)
            }
        }

        let totalTraversalSec = {
            let dur = clock.now - traversalStart
            return Double(dur.components.seconds) + Double(dur.components.attoseconds) / 1e18
        }()

        // Clean up: explicitly release all remaining leases before ending
        for (_, lease) in activeLeases {
            await lease.release()
        }
        activeLeases.removeAll()

        let finalStats = await store.statistics()

        return LeasingResult(
            stepsTraversed: viewportWindowStarts.count,
            peakConcurrentLeases: peakConcurrent,
            cacheHits: finalStats.hits,
            cacheMisses: finalStats.extractions,
            evictions: finalStats.evictions,
            peakCachedBytes: peakCachedBytes,
            peakDiskFootprintBytes: peakDiskBytes,
            hitLatency: MeasurementStats(samples: hitLatencies),
            missLatency: MeasurementStats(samples: missLatencies),
            totalTraversalSec: totalTraversalSec
        )
    }
}
