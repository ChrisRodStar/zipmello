import Foundation
import Dispatch
import Darwin
import SystemPackage

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

        fm.createFile(atPath: staging.path, contents: nil)
        try writeStaging(staging, assets: assets, sizes: sizes, limits: limits, tuning: tuning, progress: progress, total: total)

        try Task.checkCancellation()
        let handle = try FileHandle(forWritingTo: staging)
        do { try handle.synchronize(); try handle.close() }
        catch { try? handle.close(); throw error }
        try fm.moveItem(at: staging, to: destination)
    }

    private func writeStaging(_ staging: URL, assets: [ArchiveAsset], sizes: [UInt64], limits: ArchiveLimits, tuning: ArchiveTuning, progress: ArchiveProgressHandler?, total: UInt64) throws {
        try ZipBinaryWriter.writeArchive(
            to: staging,
            assets: assets,
            sizes: sizes,
            limits: limits,
            tuning: tuning,
            progress: progress,
            totalBytes: total
        )
        try checkOutputSize(staging, limits: limits)
    }

    private func checkOutputSize(_ staging: URL, limits: ArchiveLimits) throws {
        let bytes = try staging.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard bytes >= 0, UInt64(bytes) <= limits.maximumArchiveBytes else { throw ArchiveFailure.archiveTooLarge }
    }
}
