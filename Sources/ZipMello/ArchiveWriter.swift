import Foundation
import Dispatch
import Darwin
import SystemPackage
import ZIPFoundation

public actor ArchiveWriter {
    private nonisolated let executor = DispatchSerialQueue(label: "ZipMello.writer", qos: .utility)
    public nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
    public init() {}

    /// Writes members in supplied order, without adding a parent folder. Suitable for CBZ.
    public func create(at destination: URL, assets: [ArchiveAsset], limits: ArchiveLimits = .exporting, tuning: ArchiveTuning = .init(), progress: ArchiveProgressHandler? = nil) throws {
        try limits.validate()
        try tuning.validate()
        try Task.checkCancellation()
        guard destination.isFileURL else { throw ArchiveFailure.invalidSource(destination.absoluteString) }
        guard assets.count <= limits.maximumEntries else { throw ArchiveFailure.tooManyEntries }
        let fm = FileManager.default
        guard !fm.fileExists(atPath: destination.path) else { throw ArchiveFailure.destinationExists }
        var seen = Set<String>()
        var total: UInt64 = 0
        let sizes: [UInt64] = try assets.map { asset in
            let directory: Bool
            if case .directory = asset.content { directory = true } else { directory = false }
            try ArchivePath.validate(asset.path, directory: directory)
            guard seen.insert(asset.path).inserted else { throw ArchiveFailure.duplicatePath(asset.path) }
            let size: UInt64
            switch asset.content {
            case .directory: size = 0
            case .bytes(let bytes): size = UInt64(bytes.count)
            case .file(let url):
                guard url.isFileURL else { throw ArchiveFailure.invalidSource(url.absoluteString) }
                let attrs = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard attrs.isRegularFile == true, attrs.isSymbolicLink != true,
                      let count = attrs.fileSize, count >= 0 else { throw ArchiveFailure.invalidSource(url.path) }
                size = UInt64(count)
            }
            guard size <= limits.maximumEntryBytes, size <= UInt64(Int64.max) else { throw ArchiveFailure.memberTooLarge(asset.path) }
            let sum = total.addingReportingOverflow(size)
            guard !sum.overflow, sum.partialValue <= limits.maximumExpandedBytes else { throw ArchiveFailure.expandedArchiveTooLarge }
            total = sum.partialValue
            return size
        }
        _ = try ArchiveTreePlan(members: zip(assets, sizes).map { asset, size in
            let directory: Bool
            if case .directory = asset.content { directory = true } else { directory = false }
            return ArchiveMember(path: asset.path, uncompressedBytes: size, compressedBytes: 0, isDirectory: directory)
        })
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".archive-" + UUID().uuidString)
        defer { try? fm.removeItem(at: staging) }
        do { try writeStaging(staging, assets: assets, sizes: sizes, limits: limits, tuning: tuning, progress: progress, total: total) }
        catch Archive.ArchiveError.invalidEntrySize { throw ArchiveFailure.archiveTooLarge }
        try Task.checkCancellation()
        let handle = try FileHandle(forWritingTo: staging)
        do { try handle.synchronize(); try handle.close() }
        catch { try? handle.close(); throw error }
        try fm.moveItem(at: staging, to: destination)
    }

    private func writeStaging(_ staging: URL, assets: [ArchiveAsset], sizes: [UInt64], limits: ArchiveLimits, tuning: ArchiveTuning, progress: ArchiveProgressHandler?, total: UInt64) throws {
        let archive = try BulkArchiveWriter(url: staging, maximumBytes: limits.maximumArchiveBytes)
        var completed: UInt64 = 0
        var entryNumber = 0
        progress?(.init(completedBytes: 0, totalBytes: total, completedEntries: 0, totalEntries: assets.count))
        for (asset, size) in zip(assets, sizes) {
            try Task.checkCancellation()
            let handle: FileDescriptor?
            var initial = stat()
            if case .file(let url) = asset.content {
                let descriptor = try FileDescriptor.open(url.path, .readOnly, options: [.noFollow])
                guard fstat(descriptor.rawValue, &initial) == 0, initial.st_mode & S_IFMT == S_IFREG,
                      initial.st_size >= 0, UInt64(initial.st_size) == size else {
                    try? descriptor.close()
                    throw ArchiveFailure.invalidSource(asset.path)
                }
                handle = descriptor
            }
            else { handle = nil }
            defer { try? handle?.close() }
            let directory: Bool
            if case .directory = asset.content { directory = true } else { directory = false }
            let path = directory && !asset.path.hasSuffix("/") ? asset.path + "/" : asset.path
            try archive.append(path: path, size: Int64(size), deflate: !directory && asset.compression == .deflate,
                                  bufferSize: limits.bufferBytes, wholeBufferLimit: tuning.wholeBufferDeflateLimit, isDirectory: directory) { offset, count in
                try Task.checkCancellation()
                let chunk: Data
                switch asset.content {
                case .directory: chunk = Data()
                case .bytes(let data): chunk = data.subdata(in: Int(offset)..<(Int(offset) + count))
                case .file:
                    guard let handle else { throw ArchiveFailure.invalidSource(asset.path) }
                    var bytes = Data(count: count)
                    try bytes.withUnsafeMutableBytes { target in
                        var completed = 0
                        while completed < count {
                            try Task.checkCancellation()
                            let amount = try handle.read(into: .init(rebasing: target[completed...]))
                            guard amount > 0 else { throw ArchiveFailure.sizeMismatch(asset.path) }
                            completed += amount
                        }
                    }
                    chunk = bytes
                }
                guard chunk.count == count else { throw ArchiveFailure.sizeMismatch(asset.path) }
                progress?(.init(completedBytes: completed + UInt64(offset) + UInt64(count), totalBytes: total,
                                completedEntries: entryNumber, totalEntries: assets.count))
                return chunk
            }
            if let handle {
                var final = stat()
                guard fstat(handle.rawValue, &final) == 0, final.st_size == initial.st_size,
                      final.st_mtimespec.tv_sec == initial.st_mtimespec.tv_sec,
                      final.st_mtimespec.tv_nsec == initial.st_mtimespec.tv_nsec,
                      final.st_ctimespec.tv_sec == initial.st_ctimespec.tv_sec,
                      final.st_ctimespec.tv_nsec == initial.st_ctimespec.tv_nsec else {
                    throw ArchiveFailure.invalidSource(asset.path)
                }
            }
            try checkOutputSize(staging, limits: limits)
            completed += size; entryNumber += 1
            progress?(.init(completedBytes: completed, totalBytes: total, completedEntries: entryNumber, totalEntries: assets.count))
        }
        do { try archive.finish() }
        catch Archive.ArchiveError.invalidEntrySize { throw ArchiveFailure.archiveTooLarge }
        try checkOutputSize(staging, limits: limits)
    }

    private func checkOutputSize(_ staging: URL, limits: ArchiveLimits) throws {
        let bytes = try staging.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard bytes >= 0, UInt64(bytes) <= limits.maximumArchiveBytes else { throw ArchiveFailure.archiveTooLarge }
    }
}
