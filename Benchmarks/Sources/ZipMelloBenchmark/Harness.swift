import Foundation

public struct WorkloadRunResult: Sendable {
    public let durationSeconds: Double
    public let sinkMetric: Int

    public init(durationSeconds: Double, sinkMetric: Int) {
        self.durationSeconds = durationSeconds
        self.sinkMetric = sinkMetric
    }
}

public protocol HeadToHeadWorkload: Sendable {
    var name: String { get }
    func prepare() async throws
    /// Executes one iteration of the ZipMello workload, measuring only the defined timed region.
    func runZipMello() async throws -> WorkloadRunResult
    /// Executes one iteration of the ZIPFoundation workload, measuring only the defined timed region.
    func runZIPFoundation() async throws -> WorkloadRunResult
    /// Deep validation executed outside the timer (SHA-256 payload digests and byte counts).
    func validate() async throws
}

public enum BenchmarkHarness {
    public static func measure(
        workload: HeadToHeadWorkload,
        pairCount: Int = 10,
        targetSampleDuration: Double = 0.35
    ) async throws -> HeadToHeadResult {
        try await workload.prepare()

        // Calibration: measure 1 run of each engine to calibrate the inner-loop iteration count
        let calibZM = try await workload.runZipMello()
        let calibZF = try await workload.runZIPFoundation()
        let maxSingleSec = max(calibZM.durationSeconds, calibZF.durationSeconds, 0.0005)

        // Target ~350 ms per sample, but at least 1 iteration and at most 50
        let targetIterations = max(1, min(50, Int((targetSampleDuration / maxSingleSec).rounded(.up))))

        // Discard 2 warmup pairs (alternating A->B, B->A) to prime OS page cache, JIT/allocators, and scheduler
        // Round 1: ZipMello -> ZIPFoundation
        for _ in 0..<targetIterations {
            _ = try await workload.runZipMello()
        }
        for _ in 0..<targetIterations {
            _ = try await workload.runZIPFoundation()
        }
        // Round 2: ZIPFoundation -> ZipMello
        for _ in 0..<targetIterations {
            _ = try await workload.runZIPFoundation()
        }
        for _ in 0..<targetIterations {
            _ = try await workload.runZipMello()
        }
        try await workload.validate()

        var zipMelloTimes: [Double] = []
        var zipFoundationTimes: [Double] = []
        var pairedRatios: [Double] = []

        // Paired sampling with alternating execution order:
        // Even pairs: ZipMello -> ZIPFoundation (5 pairs)
        // Odd pairs:  ZIPFoundation -> ZipMello (5 pairs)
        for pairIndex in 0..<pairCount {
            let zmSec: Double
            let zfSec: Double

            if pairIndex % 2 == 0 {
                // ZipMello first
                var zmDurationSum: Double = 0.0
                var zmAccum = 0
                for _ in 0..<targetIterations {
                    let res = try await workload.runZipMello()
                    zmDurationSum += res.durationSeconds
                    zmAccum &+= res.sinkMetric
                }
                zmSec = zmDurationSum / Double(targetIterations)
                blackHole(zmAccum)

                // ZIPFoundation second
                var zfDurationSum: Double = 0.0
                var zfAccum = 0
                for _ in 0..<targetIterations {
                    let res = try await workload.runZIPFoundation()
                    zfDurationSum += res.durationSeconds
                    zfAccum &+= res.sinkMetric
                }
                zfSec = zfDurationSum / Double(targetIterations)
                blackHole(zfAccum)
            } else {
                // ZIPFoundation first
                var zfDurationSum: Double = 0.0
                var zfAccum = 0
                for _ in 0..<targetIterations {
                    let res = try await workload.runZIPFoundation()
                    zfDurationSum += res.durationSeconds
                    zfAccum &+= res.sinkMetric
                }
                zfSec = zfDurationSum / Double(targetIterations)
                blackHole(zfAccum)

                // ZipMello second
                var zmDurationSum: Double = 0.0
                var zmAccum = 0
                for _ in 0..<targetIterations {
                    let res = try await workload.runZipMello()
                    zmDurationSum += res.durationSeconds
                    zmAccum &+= res.sinkMetric
                }
                zmSec = zmDurationSum / Double(targetIterations)
                blackHole(zmAccum)
            }

            zipMelloTimes.append(zmSec)
            zipFoundationTimes.append(zfSec)
            if zmSec > 0 {
                pairedRatios.append(zfSec / zmSec)
            }

            // Outside the timer: verify data integrity
            try await workload.validate()
        }

        let zmStats = MeasurementStats(samples: zipMelloTimes)
        let zfStats = MeasurementStats(samples: zipFoundationTimes)

        return HeadToHeadResult(
            benchmarkName: workload.name,
            baseline: zfStats,
            candidate: zmStats,
            pairedRatios: pairedRatios
        )
    }

    @inline(never)
    private static func blackHole<T>(_ value: T) {
        _ = value
    }
}
