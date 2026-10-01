import Foundation

extension ArchiveReader {
    /// Reads and decompresses the raw bytes of a single archive entry in one static call.
    ///
    /// This convenience method automatically opens an `ArchiveReader` session, performs the read,
    /// and guarantees the reader is closed even if decompression fails.
    ///
    /// - Parameters:
    ///   - entry: The relative path of the member within the archive.
    ///   - archiveURL: File URL pointing to the `.zip` or `.cbz` archive.
    ///   - lookup: Member lookup resolution strategy (`.exact` or `.compatible`).
    ///   - limits: Resource limits governing file size, member count, and memory allocation.
    /// - Returns: Complete uncompressed byte content for the requested entry.
    /// - Throws: `ArchiveFailure` or POSIX errors if the file cannot be opened, located, or decompressed.
    public static func read(
        entry: String,
        from archiveURL: URL,
        lookup: ArchiveLookup = .exact,
        limits: ArchiveLimits = .init()
    ) async throws -> Data {
        let reader = try await ArchiveReader.open(archiveURL, limits: limits)
        do {
            let data = try await reader.read(entry, lookup: lookup)
            await reader.close()
            return data
        } catch {
            await reader.close()
            throw error
        }
    }

    /// Extracts a single archive entry directly to a destination file URL in one static call.
    ///
    /// Extraction streams through temporary staging to ensure incomplete or corrupt files
    /// are never published to the destination URL.
    ///
    /// - Parameters:
    ///   - entry: The relative path of the member within the archive.
    ///   - archiveURL: File URL pointing to the source archive.
    ///   - destinationURL: Target file path where the extracted content will be written.
    ///   - lookup: Member lookup resolution strategy.
    ///   - limits: Resource limits.
    /// - Throws: `ArchiveFailure` if the entry is missing, traversal occurs, or checksum mismatches.
    public static func extract(
        entry: String,
        from archiveURL: URL,
        to destinationURL: URL,
        lookup: ArchiveLookup = .exact,
        limits: ArchiveLimits = .init()
    ) async throws {
        let reader = try await ArchiveReader.open(archiveURL, limits: limits)
        do {
            try await reader.extract(entry, to: destinationURL, lookup: lookup)
            await reader.close()
        } catch {
            await reader.close()
            throw error
        }
    }

    /// Recursively extracts all archive entries into a target destination directory in one static call.
    ///
    /// Validates all entry paths prior to writing to disk to prevent directory traversal or collision vulnerabilities.
    ///
    /// - Parameters:
    ///   - archiveURL: File URL of the archive to extract.
    ///   - destinationFolder: Directory where extracted files and subdirectories will be created.
    ///   - limits: Resource limits.
    ///   - progress: Optional callback tracking extraction bytes and progress milestones.
    /// - Throws: `ArchiveFailure` on traversal violation, checksum failure, or cancellation.
    public static func extractAll(
        from archiveURL: URL,
        to destinationFolder: URL,
        limits: ArchiveLimits = .init(),
        progress: ArchiveProgressHandler? = nil
    ) async throws {
        let reader = try await ArchiveReader.open(archiveURL, limits: limits)
        do {
            try await reader.extractAll(to: destinationFolder, progress: progress)
            await reader.close()
        } catch {
            await reader.close()
            throw error
        }
    }
}

extension ArchiveWriter {
    /// Recursively creates a ZIP archive from a local directory in a single static call.
    ///
    /// - Parameters:
    ///   - destinationURL: Output archive destination URL. Must not exist.
    ///   - directoryURL: Local directory containing the files to package.
    ///   - compression: Compression algorithm (.deflate or .stored). Defaults to `.deflate`.
    ///   - skipHiddenFiles: When `true`, dotfiles and hidden files are excluded. Defaults to `false`.
    ///   - progress: Optional progress reporting callback.
    /// - Throws: `ArchiveFailure` or POSIX errors if archiving fails.
    public static func create(
        at destinationURL: URL,
        from directoryURL: URL,
        compression: ArchiveCompression = .deflate,
        skipHiddenFiles: Bool = false,
        progress: ArchiveProgressHandler? = nil
    ) async throws {
        try await ArchiveWriter().create(
            at: destinationURL,
            directory: directoryURL,
            skipHiddenFiles: skipHiddenFiles,
            compression: compression,
            progress: progress
        )
    }

    /// Creates a ZIP archive from an array of structured assets in a single static call.
    ///
    /// - Parameters:
    ///   - destinationURL: Output archive destination URL. Must not exist.
    ///   - assets: List of `ArchiveAsset` items representing files, byte buffers, or directories.
    ///   - limits: Security constraints and size caps.
    ///   - progress: Optional progress reporting callback.
    /// - Throws: `ArchiveFailure` or POSIX errors if archiving fails.
    public static func create(
        at destinationURL: URL,
        assets: [ArchiveAsset],
        limits: ArchiveLimits = .init(),
        progress: ArchiveProgressHandler? = nil
    ) async throws {
        try await ArchiveWriter().create(
            at: destinationURL,
            assets: assets,
            limits: limits,
            progress: progress
        )
    }
}
