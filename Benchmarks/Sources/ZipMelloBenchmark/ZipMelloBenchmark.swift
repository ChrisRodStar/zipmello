import Foundation
import Dispatch
import ZipMello
import ZIPFoundation
import UpstreamZIPFoundation

private enum BenchError: Error { case invalidResult, missingEntry, invalidArguments }

/// Baseline has the same queue isolation and per-read actor hop as the new reader.
private actor UpstreamReader {
    private nonisolated let executor = DispatchSerialQueue(label: "benchmark.upstream", qos: .utility)
    nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
    private var archive: UpstreamZIPFoundation.Archive?
    func open(_ url: URL) throws {
        archive = try UpstreamZIPFoundation.Archive(url: url, accessMode: .read, pathEncoding: nil)
    }
    func read(_ path: String) throws -> Data {
        guard let archive, let entry = archive[path] else { throw BenchError.missingEntry }
        var data = Data()
        let checksum = try archive.extract(entry) { data.append($0) }
        guard checksum == entry.checksum else { throw BenchError.invalidResult }
        return data
    }
    func close() { archive = nil }
}

private struct Workload {
    let name: String
    let files: [URL]
    let contents: [Data]
    let compressed: Bool
    let reads: Int
    var paths: [String] { files.map(\.lastPathComponent) }
    var expandedBytes: Int { contents.reduce(0) { $0 + $1.count } }
}

private struct Measurement: Codable {
    let workload: String
    let operation: String
    let upstreamMilliseconds: [Double]
    let mellokuMilliseconds: [Double]
    let entryCount: Int
    let expandedBytes: Int
    let operationsPerSample: Int
}

private struct Report: Codable {
    let generatedAt: String
    let platform: String
    let upstreamRevision: String
    let configuration: String
    let warmupRounds: Int
    let measuredRounds: Int
    let notes: [String]
    let measurements: [Measurement]
}

@main
struct ZipMelloBenchmark {
    static func main() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count <= 1 else { throw BenchError.invalidArguments }
        let root = FileManager.default.temporaryDirectory.appending(path: "zipmello-benchmark-" + UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workloads = try makeWorkloads(root)
        var measurements: [Measurement] = []
        let rounds = 7
        for workload in workloads {
            let paths = workload.paths
            let archiveURL = root.appending(path: workload.name + ".zip")
            try upstreamWrite(archiveURL, workload: workload)
            print("Benchmarking \(workload.name): \(workload.files.count) entries, \(workload.expandedBytes) bytes")
            let indices = (0..<workload.reads).map { ($0 * 7919 + workload.files.count - 1) % workload.files.count }
            for operation in ["open_and_first_read", "reused_random_reads", "create_archive"] {
                var old: [Double] = [], new: [Double] = []
                for round in 0...rounds {
                    // Alternate order to avoid systematically favoring the second provider.
                    for isNew in (round.isMultiple(of: 2) ? [false, true] : [true, false]) {
                        let elapsed: Double
                        switch operation {
                        case "open_and_first_read":
                            elapsed = try await time {
                                let index = workload.files.count - 1
                                let bytes: Data
                                if isNew {
                                    let reader = try await ArchiveReader.open(archiveURL)
                                    bytes = try await reader.read(paths[index])
                                    await reader.close()
                                } else {
                                    let reader = UpstreamReader()
                                    try await reader.open(archiveURL)
                                    bytes = try await reader.read(paths[index])
                                    await reader.close()
                                }
                                guard bytes == workload.contents[index] else { throw BenchError.invalidResult }
                            }
                        case "reused_random_reads":
                            if isNew {
                                let reader = try await ArchiveReader.open(archiveURL)
                                elapsed = try await time {
                                    for index in indices {
                                        let bytes = try await reader.read(paths[index])
                                        guard bytes == workload.contents[index] else { throw BenchError.invalidResult }
                                    }
                                }
                                await reader.close()
                            } else {
                                let reader = UpstreamReader()
                                try await reader.open(archiveURL)
                                elapsed = try await time {
                                    for index in indices {
                                        let bytes = try await reader.read(paths[index])
                                        guard bytes == workload.contents[index] else { throw BenchError.invalidResult }
                                    }
                                }
                                await reader.close()
                            }
                        default:
                            let output = root.appending(path: "output-" + UUID().uuidString + ".cbz")
                            elapsed = try await time {
                                if isNew {
                                    let assets = workload.files.map {
                                        ArchiveAsset(path: $0.lastPathComponent, content: .file($0), compression: workload.compressed ? .deflate : .stored)
                                    }
                                    try await ArchiveWriter().create(at: output, assets: assets)
                                } else { try upstreamWrite(output, workload: workload) }
                            }
                            // Verify every output outside the measured creation interval.
                            try verify(output, workload: workload)
                            try FileManager.default.removeItem(at: output)
                        }
                        if round > 0 {
                            if isNew { new.append(elapsed) } else { old.append(elapsed) }
                        }
                    }
                }
                measurements.append(.init(workload: workload.name, operation: operation,
                                          upstreamMilliseconds: old, mellokuMilliseconds: new,
                                          entryCount: workload.files.count, expandedBytes: workload.expandedBytes,
                                          operationsPerSample: operation == "reused_random_reads" ? workload.reads : 1))
                print(String(format: "  %@: upstream %.3f ms, Melloku %.3f ms", operation, median(old), median(new)))
            }
        }
        // Equal-buffer engine comparisons exclude the wrapper, actor hops and archive lookup.
        let engine = workloads.last!
        let engineURL = root.appending(path: "engine.zip")
        try upstreamWrite(engineURL, workload: engine)
        for operation in ["engine_extract_64KiB", "engine_create_64KiB"] {
            var old: [Double] = [], new: [Double] = []
            for round in 0...rounds {
                for isNew in (round.isMultiple(of: 2) ? [false, true] : [true, false]) {
                    let output = root.appending(path: "engine-output-" + UUID().uuidString + ".zip")
                    let elapsed = try await time {
                        if operation == "engine_extract_64KiB" {
                            if isNew {
                                let archive = try ZIPFoundation.Archive(url: engineURL, accessMode: .read)
                                for (index, entry) in archive.enumerated() {
                                    var data = Data()
                                    let crc = try archive.extract(entry, bufferSize: 65_536) { data.append($0) }
                                    guard crc == entry.checksum, data == engine.contents[index] else { throw BenchError.invalidResult }
                                }
                            } else {
                                let archive = try UpstreamZIPFoundation.Archive(url: engineURL, accessMode: .read, pathEncoding: nil)
                                for (index, entry) in archive.enumerated() {
                                    var data = Data()
                                    let crc = try archive.extract(entry, bufferSize: 65_536) { data.append($0) }
                                    guard crc == entry.checksum, data == engine.contents[index] else { throw BenchError.invalidResult }
                                }
                            }
                        } else if isNew {
                            let archive = try ZIPFoundation.Archive(url: output, accessMode: .create)
                            for file in engine.files {
                                try archive.addEntry(with: file.lastPathComponent, fileURL: file, compressionMethod: .deflate, bufferSize: 65_536)
                            }
                        } else { try upstreamWrite(output, workload: engine, bufferSize: 65_536, synchronize: false) }
                    }
                    if operation == "engine_create_64KiB" {
                        try verify(output, workload: engine)
                        try FileManager.default.removeItem(at: output)
                    }
                    if round > 0 {
                        if isNew { new.append(elapsed) } else { old.append(elapsed) }
                    }
                }
            }
            measurements.append(.init(workload: "model", operation: operation, upstreamMilliseconds: old,
                                      mellokuMilliseconds: new, entryCount: engine.files.count,
                                      expandedBytes: engine.expandedBytes, operationsPerSample: engine.files.count))
            print(String(format: "  %@: upstream %.3f ms, fork %.3f ms", operation, median(old), median(new)))
        }
        let report = Report(generatedAt: Date.now.formatted(.iso8601), platform: ProcessInfo.processInfo.operatingSystemVersionString,
                            upstreamRevision: "e7a17d57c583067eaa6659cd6d9521265b7664e9", configuration: "release",
                            warmupRounds: 1, measuredRounds: rounds,
                            notes: ["Synthetic deterministic fixtures; no real user archives or network.",
                                    "Warm filesystem cache; no claim of cold-storage performance or device results.",
                                    "Both reader APIs use DispatchSerialQueue-backed actors and verify CRC/output bytes.",
                                    "Public API comparison: upstream 16 KiB defaults versus Melloku 64 KiB, with Melloku indexing/path/budget checks.",
                                    "Reused reads exclude opening/index setup; open-and-first-read includes them.",
                                    "Both public writers synchronize file content. Melloku adds validation, staging and publication; upstream writes directly.",
                                    "Equal-buffer engine comparisons use 64 KiB and identical direct ZIP API operations; engine creation excludes synchronize for both.",
                                    "Fixture generation and writer-output verification are excluded from timings; read-output equality is included for both.",
                                    "Alternating provider order, one warmup then seven measured samples; retain all samples."],
                            measurements: measurements)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        if let path = args.first { try data.write(to: URL(filePath: path), options: .atomic) }
        else { print(String(decoding: data, as: UTF8.self)) }
    }

    private static func time(isolation: isolated (any Actor)? = #isolation,
                             _ operation: () async throws -> Void) async rethrows -> Double {
        let start = ContinuousClock.now
        try await operation()
        let duration = start.duration(to: .now).components
        return Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15
    }

    private static func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }

    private static func upstreamWrite(_ url: URL, workload: Workload, bufferSize: Int = 16_384, synchronize: Bool = true) throws {
        do {
            let archive = try UpstreamZIPFoundation.Archive(url: url, accessMode: .create, pathEncoding: nil)
            for file in workload.files {
                try archive.addEntry(with: file.lastPathComponent, fileURL: file,
                                     compressionMethod: workload.compressed ? .deflate : .none, bufferSize: bufferSize)
            }
        }
        if synchronize {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.synchronize()
        }
    }

    private static func verify(_ url: URL, workload: Workload) throws {
        let archive = try UpstreamZIPFoundation.Archive(url: url, accessMode: .read, pathEncoding: nil)
        var count = 0
        for entry in archive {
            guard count < workload.files.count, entry.path == workload.files[count].lastPathComponent else { throw BenchError.invalidResult }
            var bytes = Data()
            let checksum = try archive.extract(entry, bufferSize: 65_536) { bytes.append($0) }
            guard checksum == entry.checksum, bytes == workload.contents[count] else { throw BenchError.invalidResult }
            count += 1
        }
        guard count == workload.files.count else { throw BenchError.invalidResult }
    }

    private static func makeWorkloads(_ root: URL) throws -> [Workload] {
        var state: UInt64 = 0x12345678
        func pattern(size: Int, compressible: Bool) -> Data {
            let chunk = (0..<4096).map { index -> UInt8 in
                state = state &* 6364136223846793005 &+ 1
                return compressible && index.isMultiple(of: 2) ? 0 : UInt8(truncatingIfNeeded: state >> 32)
            }
            return Data((0..<size).map { chunk[$0 % chunk.count] })
        }
        var results: [Workload] = []
        for (name, count, size, compressed, reads) in [
            ("source", 8, 262_144, true, 16),
            ("cbz", 128, 262_144, false, 64),
            ("dictionary", 4000, 512, true, 300),
            ("model", 8, 2_097_152, true, 16)
        ] {
            let directory = root.appending(path: name, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let content = pattern(size: size, compressible: compressed)
            var files: [URL] = [], contents: [Data] = []
            for index in 0..<count {
                let file = directory.appending(path: String(format: "%05d.bin", index))
                try content.write(to: file)
                files.append(file); contents.append(content)
            }
            results.append(.init(name: name, files: files, contents: contents, compressed: compressed, reads: reads))
        }
        return results
    }
}
