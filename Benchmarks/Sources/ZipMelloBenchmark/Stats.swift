import Foundation

public struct MeasurementStats: Sendable, Codable {
    public let median: Double
    public let mad: Double
    public let samples: [Double]

    public init(samples: [Double]) {
        let sortedSamples = samples.sorted()
        self.samples = sortedSamples

        guard !sortedSamples.isEmpty else {
            self.median = 0
            self.mad = 0
            return
        }

        let count = sortedSamples.count
        let med: Double
        if count % 2 == 1 {
            med = sortedSamples[count / 2]
        } else {
            med = (sortedSamples[count / 2 - 1] + sortedSamples[count / 2]) / 2.0
        }
        self.median = med

        // Median Absolute Deviation (MAD)
        let deviations = sortedSamples.map { abs($0 - med) }.sorted()
        if deviations.isEmpty {
            self.mad = 0
        } else if deviations.count % 2 == 1 {
            self.mad = deviations[deviations.count / 2]
        } else {
            self.mad = (deviations[deviations.count / 2 - 1] + deviations[deviations.count / 2]) / 2.0
        }
    }

    public var formattedDuration: String {
        let ms = median * 1000.0
        let madMs = mad * 1000.0
        if ms < 1.0 {
            return String(format: "%.3f ms ± %.3f ms MAD", ms, madMs)
        } else {
            return String(format: "%.2f ms ± %.2f ms MAD", ms, madMs)
        }
    }
}

public struct HeadToHeadResult: Sendable, Codable {
    public let benchmarkName: String
    public let baseline: MeasurementStats
    public let candidate: MeasurementStats
    public let pairedSpeedup: MeasurementStats

    public init(
        benchmarkName: String,
        baseline: MeasurementStats,
        candidate: MeasurementStats,
        pairedRatios: [Double]
    ) {
        self.benchmarkName = benchmarkName
        self.baseline = baseline
        self.candidate = candidate
        self.pairedSpeedup = MeasurementStats(samples: pairedRatios)
    }

    public var speedup: Double {
        pairedSpeedup.median
    }

    public var formattedSpeedup: String {
        String(format: "%.2f×", pairedSpeedup.median)
    }
}
