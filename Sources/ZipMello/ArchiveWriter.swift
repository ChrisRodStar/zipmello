import Foundation
import Dispatch
import Darwin
import SystemPackage

/// High-performance actor for creating standard and ZIP64 archives with deterministic output.
///
/// `ArchiveWriter` stages all archive construction in a temporary file adjacent to the intended
/// destination (`.archive-<UUID>`) before atomically renaming it into place. This guarantees that
/// failed, interrupted, or cancelled writes never leave corrupt or incomplete archives at the destination.
public actor ArchiveWriter {
    private nonisolated let executor = DispatchSerialQueue(label: "ZipMello.writer", qos: .utility)
    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        executor.asUnownedSerialExecutor()
    }

    public init() {}

    /// Writes archive assets in the supplied order without prepending a root folder.
    ///
    /// This method is well suited for CBZ comic archives, package bundles, and flat asset containers.
    ///
    /// - Parameters:
    ///   - destination: File URL where the finalized archive will be written. Must not already exist.
    ///   - assets: Ordered list of files, byte buffers, or directory markers to package.
    ///   - limits: Resource limits safeguarding against path traversal and oversized archives.
    ///   - tuning: Buffer size and compression level configurations.
    ///   - progress: Optional callback invoked with cumulative bytes processed and total uncompressed bytes.
    public func create(
        at destination: URL,
        assets: [ArchiveAsset],
        limits: ArchiveLimits = .exporting,
        tuning: ArchiveTuning = .init(),
        progress: ArchiveProgressHandler? = nil
    ) throws {
        try limits.validate()
        try tuning.validate()
        try Task.checkCancellation()

        guard destination.isFileURL else {
            throw ArchiveFailure.invalidSource(destination.absoluteString)
        }
        guard assets.count <= limits.maximumEntries else {
            throw ArchiveFailure.tooManyEntries
        }

        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw ArchiveFailure.destinationExists
        }

        var seenPaths = Set<String>()
        var totalUncompressedBytes: UInt64 = 0

        let sizes: [UInt64] = try assets.map { asset in
            let isDirectory: Bool
            if case .directory = asset.content {
                isDirectory = true
            } else {
                isDirectory = false
            }

            try ArchivePath.validate(asset.path, directory: isDirectory)
            guard seenPaths.insert(asset.path).inserted else {
                throw ArchiveFailure.duplicatePath(asset.path)
            }

            let size: UInt64
            switch asset.content {
            case .directory:
                size = 0

            case .bytes(let bytes):
                size = UInt64(bytes.count)

            case .file(let url):
                guard url.isFileURL else {
                    throw ArchiveFailure.invalidSource(url.absoluteString)
                }
                let attrs = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard attrs.isRegularFile == true,
                      attrs.isSymbolicLink != true,
                      let count = attrs.fileSize,
                      count >= 0 else {
                    throw ArchiveFailure.invalidSource(url.path)
                }
                size = UInt64(count)
            }

            guard size <= limits.maximumEntryBytes, size <= UInt64(Int64.max) else {
                throw ArchiveFailure.memberTooLarge(asset.path)
            }

            let sum = totalUncompressedBytes.addingReportingOverflow(size)
            guard !sum.overflow, sum.partialValue <= limits.maximumExpandedBytes else {
                throw ArchiveFailure.expandedArchiveTooLarge
            }
            totalUncompressedBytes = sum.partialValue
            return size
        }

        // Validate tree integrity before touching disk storage.
        _ = try ArchiveTreePlan(members: zip(assets, sizes).map { asset, size in
            let isDirectory: Bool
            if case .directory = asset.content {
                isDirectory = true
            } else {
                isDirectory = false
            }
            return ArchiveMember(
                path: asset.path,
                uncompressedBytes: size,
                compressedBytes: 0,
                isDirectory: isDirectory
            )
        })

        // Staging file in the destination's parent folder ensures atomic same-filesystem rename.
        let stagingURL = destination.deletingLastPathComponent().appendingPathComponent(".archive-" + UUID().uuidString)
        defer {
            try? fileManager.removeItem(at: stagingURL)
        }

        fileManager.createFile(atPath: stagingURL.path, contents: nil)
        try writeStaging(
            stagingURL,
            assets: assets,
            sizes: sizes,
            limits: limits,
            tuning: tuning,
            progress: progress,
            total: totalUncompressedBytes
        )

        try Task.checkCancellation()

        // Flush and synchronize staging file to disk prior to renaming.
        let handle = try FileHandle(forWritingTo: stagingURL)
        do {
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }

        try fileManager.moveItem(at: stagingURL, to: destination)
    }

    private func writeStaging(
        _ staging: URL,
        assets: [ArchiveAsset],
        sizes: [UInt64],
        limits: ArchiveLimits,
        tuning: ArchiveTuning,
        progress: ArchiveProgressHandler?,
        total: UInt64
    ) throws {
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
        guard bytes >= 0, UInt64(bytes) <= limits.maximumArchiveBytes else {
            throw ArchiveFailure.archiveTooLarge
        }
    }
}
