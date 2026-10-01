import Foundation
import Darwin
import ZipMello
import ZipMelloConsumers
import UpstreamZIPFoundation

private enum Failure: Error { case arguments, invalidResult }
private actor UpstreamPageStore {
    let archiveURL: URL
    let directory: URL
    var cached: [String: URL] = [:]
    init(archiveURL: URL, directory: URL) { self.archiveURL = archiveURL; self.directory = directory }
    func file(_ path: String) throws -> URL {
        let fm = FileManager.default
        if let url = cached[path], fm.fileExists(atPath: url.path) { return url }
        let archive = try UpstreamZIPFoundation.Archive(url: archiveURL, accessMode: .read)
        guard let entry = archive[path] else { throw Failure.invalidResult }
        let destination = directory.appendingPathComponent(UUID().uuidString)
        let crc = try archive.extract(entry, to: destination)
        guard crc == entry.checksum else { throw Failure.invalidResult }
        cached[path] = destination
        return destination
    }
}
@main struct ConsumerBenchmark {
    static func main() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count == 4 else { throw Failure.arguments }
        let variant = args[0], operation = args[1], workload = args[2]
        let root = URL(filePath: args[3]), fm = FileManager.default
        let archiveURL = root.appendingPathComponent(workload + ".zip")
        let directory = root.appendingPathComponent(workload)
        let output = root.appendingPathComponent("consumer-" + UUID().uuidString)
        defer { try? fm.removeItem(at: output) }
        let paths = try fm.subpathsOfDirectory(atPath: directory.path).sorted().filter {
            (try? directory.appendingPathComponent($0).resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
        guard let first = paths.first else { throw Failure.arguments }
        let archiveData = (operation == "memory" || operation == "memory_batch") ? try Data(contentsOf: archiveURL) : Data()
        let expected = operation == "memory" ? try Data(contentsOf: directory.appendingPathComponent(first)) : Data()
        let batchPositions = operation == "memory_batch" ? (0..<64).map { ($0 * 7919 + paths.count - 1) % paths.count } : []
        let batchExpected = try batchPositions.map { try Data(contentsOf: directory.appendingPathComponent(paths[$0])) }
        var operations = paths.count
        let start = ContinuousClock.now
        switch operation {
        case "memory":
            operations = 64
            for _ in 0..<operations {
                let data: Data
                if variant == "upstream" {
                    let archive = try UpstreamZIPFoundation.Archive(data: archiveData, accessMode: .read)
                    guard let entry = archive[first] else { throw Failure.invalidResult }
                    var bytes = Data()
                    let crc = try archive.extract(entry) { bytes.append($0) }
                    guard crc == entry.checksum else { throw Failure.invalidResult }
                    data = bytes
                } else {
                    data = try await ArchiveMemoryService.shared.read(first, data: archiveData, limits: .init())
                }
                guard data == expected else { throw Failure.invalidResult }
            }
        case "memory_batch":
            operations = 64
            if variant == "upstream" {
                let archive = try UpstreamZIPFoundation.Archive(data: archiveData, accessMode: .read)
                for (number, position) in batchPositions.enumerated() {
                    guard let entry = archive[paths[position]] else { throw Failure.invalidResult }
                    var data = Data()
                    let crc = try archive.extract(entry) { data.append($0) }
                    guard crc == entry.checksum, data == batchExpected[number] else { throw Failure.invalidResult }
                }
            } else {
                let reader = try ArchiveMemoryReader(data: archiveData)
                for (number, position) in batchPositions.enumerated() {
                    guard try reader.read(paths[position]) == batchExpected[number] else { throw Failure.invalidResult }
                }
            }
        case "tree":
            if variant == "upstream" { try fm.unzipItem(at: archiveURL, to: output) }
            else { try await ArchivePackageInstaller.extract(from: archiveURL, to: output, limits: workload == "model" ? .models : .dictionaries, tuning: variant == "zipmello-small" ? .smallEntries : .init()) }
        case "export":
            if variant == "upstream" { try fm.zipItem(at: directory, to: output, shouldKeepParent: false, compressionMethod: UpstreamZIPFoundation.CompressionMethod.none) }
            else { try await ArchiveWriter().create(at: output, directory: directory) }
        case "validate":
            if variant == "upstream" {
                let archive = try UpstreamZIPFoundation.Archive(url: archiveURL, accessMode: .read)
                for entry in archive where entry.type == .file {
                    let crc = try archive.extract(entry) { _ in }
                    guard crc == entry.checksum else { throw Failure.invalidResult }
                }
            } else {
                let reader = try await ArchiveReader.open(archiveURL, limits: .dictionaries, tuning: variant == "zipmello-small" ? .smallEntries : .init())
                try await reader.validate()
                await reader.close()
            }
        case "pages":
            try fm.createDirectory(at: output, withIntermediateDirectories: true)
            operations = 128
            if variant == "upstream" {
                let store = UpstreamPageStore(archiveURL: archiveURL, directory: output)
                for number in 0..<operations {
                    let path = paths[number % min(paths.count, 16)]
                    let file = try await store.file(path)
                    guard fm.fileExists(atPath: file.path) else { throw Failure.invalidResult }
                }
            } else {
                let store = try ArchivePageStore(directory: output)
                let session = try await store.session(for: archiveURL)
                for number in 0..<operations {
                    let path = paths[number % min(paths.count, 16)]
                    let lease = try await session.lease(path)
                    guard fm.fileExists(atPath: lease.url.path) else { throw Failure.invalidResult }
                    await lease.release()
                }
                guard await store.statistics().extractions == UInt64(min(paths.count, 16)) else { throw Failure.invalidResult }
                await store.removeAll()
            }
        default: throw Failure.arguments
        }
        let elapsed = start.duration(to: .now).components
        let milliseconds = Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        let peak = usage.ru_maxrss
        // Verification is outside timing and peak-memory capture.
        if operation == "tree" {
            for path in paths {
                guard try Data(contentsOf: output.appendingPathComponent(path), options: .mappedIfSafe) == Data(contentsOf: directory.appendingPathComponent(path), options: .mappedIfSafe) else { throw Failure.invalidResult }
            }
        } else if operation == "export" {
            let archive = try UpstreamZIPFoundation.Archive(url: output, accessMode: .read)
            let entries = Dictionary(uniqueKeysWithValues: archive.map { ($0.path, $0) })
            for path in paths {
                guard let entry = entries[path] else { throw Failure.invalidResult }
                var bytes = Data()
                let crc = try archive.extract(entry) { bytes.append($0) }
                guard crc == entry.checksum, bytes == (try Data(contentsOf: directory.appendingPathComponent(path))) else { throw Failure.invalidResult }
            }
        }
        let result: [String: Any] = ["variant": variant, "operation": operation, "workload": workload,
            "milliseconds": milliseconds, "peakResidentBytes": peak, "operations": operations]
        print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
    }
}
