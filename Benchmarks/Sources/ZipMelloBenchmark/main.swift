import Foundation
import ZipMello
import ZipMelloConsumers
import ZIPFoundation

@main
struct BenchmarkMain {
    static func main() async {
        do {
            try await run()
        } catch {
            fputs("Benchmark error: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func run() async throws {
        let args = CommandLine.arguments

        if args.contains("--help") || args.contains("-h") {
            print("""
            ZipMello vs ZIPFoundation Manga & Comic Reader Benchmark Suite

            Usage:
              swift run --package-path Benchmarks -c release [options]

            Options:
              --json               Output machine-readable JSON results
              --quick              Run 2 measured pairs (1 A->B, 1 B->A) for fast smoke testing
              --pairs <count>      Number of measured pairs (default: 10)
              --seed <number>      Deterministic PRNG seed for page permutations (default: 0x123456789ABCDEF)
              --workload <filter>  Filter workload (random, concurrent, memory, discovery, leasing, or all)
              --fixture <path>     Path to a custom .cbz or .zip archive fixture
              --help, -h           Show this help message
            """)
            return
        }

        let isJSON = args.contains("--json")
        let isQuick = args.contains("--quick")

        var pairCount = isQuick ? 2 : 10
        if let idx = args.firstIndex(of: "--pairs"), idx + 1 < args.count, let val = Int(args[idx + 1]), val >= 2 {
            // Ensure even number for balanced A->B and B->A pairs
            pairCount = (val % 2 == 0) ? val : (val + 1)
        }

        var seed: UInt64 = 0x123456789ABCDEF
        if let idx = args.firstIndex(of: "--seed"), idx + 1 < args.count {
            if args[idx + 1].hasPrefix("0x") {
                seed = UInt64(args[idx + 1].dropFirst(2), radix: 16) ?? seed
            } else {
                seed = UInt64(args[idx + 1]) ?? seed
            }
        }

        var workloadFilter = "all"
        if let idx = args.firstIndex(of: "--workload"), idx + 1 < args.count {
            workloadFilter = args[idx + 1].lowercased()
        }

        // Locate default Fixtures directory relative to source file
        let packageDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ZipMelloBenchmark
            .deletingLastPathComponent() // Sources
            .deletingLastPathComponent() // Benchmarks

        let fixturesDir = packageDir.appendingPathComponent("Fixtures", isDirectory: true)
        let comicSourceDir = fixturesDir.appendingPathComponent("comic", isDirectory: true)
        let defaultFixtureURL = fixturesDir.appendingPathComponent("PepperAndCarrot_80P.cbz")

        var fixtureURL = defaultFixtureURL
        if let idx = args.firstIndex(of: "--fixture"), idx + 1 < args.count {
            fixtureURL = URL(fileURLWithPath: args[idx + 1])
        } else {
            if !isJSON {
                print("Checking benchmark fixture at \(defaultFixtureURL.lastPathComponent)...")
            }
            fixtureURL = try await FixtureGenerator.ensureFixture(
                at: defaultFixtureURL,
                comicSourceDir: comicSourceDir
            )
        }

        if !isJSON {
            print("Capturing environment metadata...")
        }
        let env = EnvironmentInfo.capture(fixtureURL: fixtureURL)

        if !isJSON {
            print("Warming up runtime and initializing test suite (\(pairCount) balanced pairs, 2 warmups)...")
        }

        var workloads: [HeadToHeadWorkload] = []

        if workloadFilter == "all" || workloadFilter.contains("random") {
            workloads.append(WorkloadRandomAccess(archiveURL: fixtureURL, seed: seed))
        }
        if workloadFilter == "all" || workloadFilter.contains("lookup") {
            workloads.append(WorkloadPathLookup(archiveURL: fixtureURL, seed: seed))
        }
        if workloadFilter == "all" || workloadFilter.contains("concurrent") {
            workloads.append(WorkloadConcurrent(archiveURL: fixtureURL))
        }
        if workloadFilter == "all" || workloadFilter.contains("memory") {
            workloads.append(WorkloadMemory(archiveURL: fixtureURL))
        }
        if workloadFilter == "all" || workloadFilter.contains("discovery") {
            workloads.append(WorkloadDiscovery(archiveURL: fixtureURL))
        }

        var results: [HeadToHeadResult] = []
        for (i, workload) in workloads.enumerated() {
            if !isJSON {
                print("[\(i + 1)/\(workloads.count)] Measuring: \(workload.name)...")
            }
            let result = try await BenchmarkHarness.measure(
                workload: workload,
                pairCount: pairCount
            )
            results.append(result)
        }

        var leasingResult: LeasingResult? = nil
        if workloadFilter == "all" || workloadFilter.contains("leasing") {
            if !isJSON {
                print("Measuring: Continuous Scroll Viewport Leasing (ArchivePageStore)...")
            }
            let cacheDir = FileManager.default.temporaryDirectory.appendingPathComponent("zipmello-bench-cache")
            let leasingWorkload = WorkloadLeasing(archiveURL: fixtureURL, cacheDir: cacheDir)
            leasingResult = try await leasingWorkload.run()
        }

        if isJSON {
            BenchmarkFormatter.printJSON(
                env: env,
                samplePairs: pairCount,
                results: results,
                leasingResult: leasingResult
            )
        } else {
            BenchmarkFormatter.printReport(
                env: env,
                samplePairs: pairCount,
                results: results,
                leasingResult: leasingResult
            )
        }
    }
}
