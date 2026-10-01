import Foundation

extension ArchiveReader {
    /// Reads the raw uncompressed data of a specific entry from an archive file in one call.
    public static func read(entry: String, from archiveURL: URL, lookup: ArchiveLookup = .exact, limits: ArchiveLimits = .init()) async throws -> Data {
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

    /// Extracts a single entry from an archive file directly to a destination file URL in one call.
    public static func extract(entry: String, from archiveURL: URL, to destinationURL: URL, lookup: ArchiveLookup = .exact, limits: ArchiveLimits = .init()) async throws {
        let reader = try await ArchiveReader.open(archiveURL, limits: limits)
        do {
            try await reader.extract(entry, to: destinationURL, lookup: lookup)
            await reader.close()
        } catch {
            await reader.close()
            throw error
        }
    }

    /// Extracts all entries from an archive file directly into a destination directory in one call.
    public static func extractAll(from archiveURL: URL, to destinationFolder: URL, limits: ArchiveLimits = .init(), progress: ArchiveProgressHandler? = nil) async throws {
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
    /// Recursively creates a ZIP archive from a local directory in one call.
    public static func create(at destinationURL: URL, from directoryURL: URL, compression: ArchiveCompression = .deflate, skipHiddenFiles: Bool = false, progress: ArchiveProgressHandler? = nil) async throws {
        try await ArchiveWriter().create(at: destinationURL, directory: directoryURL, skipHiddenFiles: skipHiddenFiles, compression: compression, progress: progress)
    }

    /// Creates a ZIP archive from structured assets in one call.
    public static func create(at destinationURL: URL, assets: [ArchiveAsset], limits: ArchiveLimits = .init(), progress: ArchiveProgressHandler? = nil) async throws {
        try await ArchiveWriter().create(at: destinationURL, assets: assets, limits: limits, progress: progress)
    }
}
