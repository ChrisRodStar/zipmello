import Foundation
import ZipMello

public enum ArchivePackageInstaller {
    /// Extracts a fresh package tree. Callers validate/compile before swapping installed content.
    public static func extract(from archive: URL, to destination: URL, limits: ArchiveLimits = .models,
                               tuning: ArchiveTuning = .init(), progress: ArchiveProgressHandler? = nil) async throws {
        let reader = try await ArchiveReader.open(archive, limits: limits, tuning: tuning)
        do { try await reader.extractAll(to: destination, progress: progress); await reader.close() }
        catch { await reader.close(); throw error }
    }
}

public struct DictionaryArchiveInspection: Sendable {
    public let title: String?
    public let entries: Int
    public let expandedBytes: UInt64
}
public enum DictionaryArchivePreflight {
    /// Streaming CRC validation precedes native conversion; no expanded tree or member Data cache.
    public static func validate(_ url: URL, limits: ArchiveLimits = .dictionaries,
                                tuning: ArchiveTuning = .smallEntries, progress: ArchiveProgressHandler? = nil) async throws -> DictionaryArchiveInspection {
        let reader = try await ArchiveReader.open(url, limits: limits, tuning: tuning)
        do {
            let members = try await reader.listing()
            try await reader.validate(progress: progress)
            var title: String?
            if let index = members.first(where: { $0.path == "index.json" }) {
                guard index.uncompressedBytes <= 4 * 1_024 * 1_024 else { throw ArchiveFailure.memberTooLarge(index.path) }
                let data = try await reader.read(index.path)
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any], let value = json["title"] as? String {
                    guard !value.isEmpty, value != ".", value != "..", !value.contains("/"), !value.contains("\\"),
                          !value.contains(":"), !value.contains("\0"), value.utf8.count <= 255 else { throw ArchiveFailure.unsafePath(value) }
                    title = value
                }
            }
            try await reader.validateSource()
            await reader.close()
            return .init(title: title, entries: members.count, expandedBytes: members.reduce(0) { $0 + $1.uncompressedBytes })
        } catch { await reader.close(); throw error }
    }
}
