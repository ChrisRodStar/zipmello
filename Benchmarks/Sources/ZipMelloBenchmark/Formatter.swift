import Foundation

public struct BenchmarkSuiteReport: Sendable, Codable {
    public let environment: EnvironmentInfo
    public let samplePairs: Int
    public let headToHeadResults: [HeadToHeadResult]
    public let leasingResult: LeasingResult?
}

public enum BenchmarkFormatter {
    private static func padLeft(_ str: String, _ length: Int) -> String {
        if str.count >= length { return str }
        return String(repeating: " ", count: length - str.count) + str
    }

    private static func padRight(_ str: String, _ length: Int) -> String {
        if str.count >= length { return str }
        return str + String(repeating: " ", count: length - str.count)
    }

    public static func printReport(
        env: EnvironmentInfo,
        samplePairs: Int,
        results: [HeadToHeadResult],
        leasingResult: LeasingResult?
    ) {
        let separator = String(repeating: "=", count: 125)
        let subSeparator = String(repeating: "-", count: 125)

        print("\n" + separator)
        print("ZipMello vs ZIPFoundation (0.9.20) — Manga & Comic Reader Benchmark Suite")
        print(separator)
        print("Environment & Methodology:")
        print("  Host:       \(env.hostModel) (\(env.cpuBrand), \(env.memoryGB) GB RAM)")
        print("  OS:         \(env.osVersion) · Swift: \(env.swiftVersion) · Mode: Release (-O)")
        print("  Checkout:   ZipMello local checkout (\(env.gitCommit)) · Locale: \(env.machineLocale)")
        print("  Method:     Sampling & Robust Statistics — \(samplePairs) balanced paired samples (2 warmups discarded)")
        print("  Cache:      Warm OS page cache (bypassFileCache = false; representative of chapter reading)")
        print("  Fixture:    Synthetic 80-page archive derived from Pepper & Carrot Episode 1 (CC-BY 4.0)")
        print("  SHA-256:    \(env.fixtureHash)")
        print(separator)
        print("Head-to-Head Engine Benchmarks (Pre-indexed lookup, 64 KB decompression buffers, CRC verified):")
        let h1 = padRight("Benchmark", 56)
        let h2 = padLeft("ZIPFoundation 0.9.20", 25)
        let h3 = padLeft("ZipMello", 25)
        let h4 = padLeft("Speedup (Median)", 16)
        print("\(h1) \(h2) \(h3) \(h4)")
        print(subSeparator)

        for res in results {
            let col1 = padRight(res.benchmarkName, 56)
            let col2 = padLeft(res.baseline.formattedDuration, 25)
            let col3 = padLeft(res.candidate.formattedDuration, 25)
            let col4 = padLeft(res.formattedSpeedup, 16)
            print("\(col1) \(col2) \(col3) \(col4)")
        }

        print(subSeparator)
        print("Verification: All operations verified outside timer with SHA-256 bitwise digests and exact byte counts.")

        if let lease = leasingResult {
            print("\nZipMello Continuous Scroll Leasing Pipeline (ArchivePageStore Bounded Cache):")
            print("  Viewport Steps Traversed: \(lease.stepsTraversed) (forward scroll, backtracks, reverse scroll)")
            print("  Peak Concurrent Leases:   \(lease.peakConcurrentLeases) pages (retained viewport window)")
            print("  Cache Telemetry:          \(lease.cacheHits) hits, \(lease.cacheMisses) misses (extractions), \(lease.evictions) evictions")
            print("  Queue Backpressure:       \(lease.queuedRequests) queued requests (peak depth: \(lease.peakQueueDepth)), \(lease.cancelledBeforeExtraction) cancelled")
            print(String(format: "  Peak Memory / Disk:       %.2f MB Peak Cached Bytes | %.2f MB Peak Disk Footprint", lease.peakCachedMB, lease.peakDiskFootprintMB))
            print(String(format: "  Cache-Hit Lease Latency:  %.3f ms ± %.3f ms MAD", lease.hitLatency.median * 1000.0, lease.hitLatency.mad * 1000.0))
            print(String(format: "  Cache-Miss Lease Latency: %.2f ms ± %.2f ms MAD (includes disk extraction)", lease.missLatency.median * 1000.0, lease.missLatency.mad * 1000.0))
            print(String(format: "  Total Viewport Traversal: %.2f ms", lease.totalTraversalSec * 1000.0))
        }

        print(separator + "\n")
    }

    public static func printJSON(
        env: EnvironmentInfo,
        samplePairs: Int,
        results: [HeadToHeadResult],
        leasingResult: LeasingResult?
    ) {
        let report = BenchmarkSuiteReport(
            environment: env,
            samplePairs: samplePairs,
            headToHeadResults: results,
            leasingResult: leasingResult
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(report),
           let jsonString = String(data: data, encoding: .utf8) {
            print(jsonString)
        }
    }
}
