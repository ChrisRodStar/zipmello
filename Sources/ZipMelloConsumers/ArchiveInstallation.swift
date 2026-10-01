import Foundation
import ZipMello

/// Streamlined package installer for extracted application resources and asset bundles.
public enum ArchivePackageInstaller {
    /// Extracts a package archive tree to a specified destination directory.
    ///
    /// - Parameters:
    ///   - archive: File URL pointing to the source archive.
    ///   - destination: File URL of the target directory to extract into.
    ///   - limits: Resource limits safeguarding against path traversal and memory exhaustion.
    ///   - tuning: I/O buffer sizing.
    ///   - progress: Optional progress reporting callback.
    public static func extract(
        from archive: URL,
        to destination: URL,
        limits: ArchiveLimits = .models,
        tuning: ArchiveTuning = .init(),
        progress: ArchiveProgressHandler? = nil
    ) async throws {
        let reader = try await ArchiveReader.open(archive, limits: limits, tuning: tuning)
        do {
            try await reader.extractAll(to: destination, progress: progress)
            await reader.close()
        } catch {
            await reader.close()
            throw error
        }
    }
}

/// Inspection summary containing verified metadata for a dictionary archive.
public struct DictionaryArchiveInspection: Sendable {
    /// Sanitized display title extracted from `index.json`, if present.
    public let title: String?

    /// Total count of valid entries contained within the dictionary archive.
    public let entries: Int

    /// Cumulative uncompressed payload bytes across all entries.
    public let expandedBytes: UInt64

    public init(title: String?, entries: Int, expandedBytes: UInt64) {
        self.title = title
        self.entries = entries
        self.expandedBytes = expandedBytes
    }
}

/// Preflight validator for dictionary and model archives.
///
/// Performs streaming CRC-32 validation over the archive without extracting members to disk
/// or retaining uncompressed payloads in memory, verifying structural integrity before downstream ingestion.
public enum DictionaryArchivePreflight {
    /// Inspects and verifies the archive integrity, extracting sanitized dictionary metadata.
    ///
    /// - Parameters:
    ///   - url: File URL of the dictionary archive.
    ///   - limits: Resource limits.
    ///   - tuning: Buffer size tuning.
    ///   - progress: Optional progress reporting callback.
    /// - Returns: Validated dictionary inspection summary.
    public static func validate(
        _ url: URL,
        limits: ArchiveLimits = .dictionaries,
        tuning: ArchiveTuning = .smallEntries,
        progress: ArchiveProgressHandler? = nil
    ) async throws -> DictionaryArchiveInspection {
        let reader = try await ArchiveReader.open(url, limits: limits, tuning: tuning)
        do {
            let members = try await reader.listing()
            try await reader.validate(progress: progress)

            var extractedTitle: String?

            if let indexMember = members.first(where: { $0.path == "index.json" }) {
                guard indexMember.uncompressedBytes <= 4 * 1024 * 1024 else {
                    throw ArchiveFailure.memberTooLarge(indexMember.path)
                }

                let data = try await reader.read(indexMember.path)
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let value = json["title"] as? String {
                    // Strictly validate title to prevent filesystem-escaping directory names.
                    let isInvalidTitle = value.isEmpty
                        || value == "."
                        || value == ".."
                        || value.contains("/")
                        || value.contains("\\")
                        || value.contains(":")
                        || value.contains("\0")
                        || value.utf8.count > 255

                    guard !isInvalidTitle else {
                        throw ArchiveFailure.unsafePath(value)
                    }
                    extractedTitle = value
                }
            }

            try await reader.validateSource()
            await reader.close()

            let totalBytes = members.reduce(0) { $0 + $1.uncompressedBytes }
            return DictionaryArchiveInspection(
                title: extractedTitle,
                entries: members.count,
                expandedBytes: totalBytes
            )
        } catch {
            await reader.close()
            throw error
        }
    }
}
