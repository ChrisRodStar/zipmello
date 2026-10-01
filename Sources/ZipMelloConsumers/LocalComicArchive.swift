import Foundation
import ZipMello

/// Errors encountered when inspecting or reading pages from a comic archive.
public enum ComicArchiveError: Error, Equatable {
    case noPages
    case invalidText(String)
    case invalidPageIndex
}

/// Represents an individual visual or textual page within a comic archive.
public struct ComicPage: Sendable, Equatable {
    /// Content classification of the page.
    public enum Kind: Sendable {
        case image
        case text
        case markdown
    }

    /// Archive relative path of the page asset.
    public let path: String

    /// Content classification of the page asset.
    public let kind: Kind

    /// Total uncompressed byte length of the page.
    public let uncompressedBytes: UInt64

    /// Archive relative path of an adjacent text description file (`.desc.txt`), if present.
    public let descriptionPath: String?

    public init(
        path: String,
        kind: Kind,
        uncompressedBytes: UInt64,
        descriptionPath: String? = nil
    ) {
        self.path = path
        self.kind = kind
        self.uncompressedBytes = uncompressedBytes
        self.descriptionPath = descriptionPath
    }
}

/// High-performance adapter for reading and inspecting comic archives (`.cbz`, `.zip`).
///
/// Automatically orders pages using natural human alphanumeric sorting (`localizedStandardCompare`),
/// pairs sidecar descriptions (`<PageNumber>.desc.txt`), and discovers `ComicInfo.xml` metadata.
public struct LocalComicArchive: Sendable {
    private let reader: ArchiveReader

    /// Ordered list of visual and textual comic pages.
    public let pages: [ComicPage]

    /// Relative path to `ComicInfo.xml` within the archive, if present.
    public let comicInfoPath: String?

    private static let recognizedImageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "webp", "gif", "heic", "avif"
    ]

    /// Opens a comic archive located at a local file URL.
    public static func open(
        _ url: URL,
        limits: ArchiveLimits = .init(),
        tuning: ArchiveTuning = .init()
    ) async throws -> LocalComicArchive {
        let reader = try await ArchiveReader.open(url, limits: limits, tuning: tuning)
        return try await prepare(reader)
    }

    /// Opens an in-memory comic archive from a `Data` buffer.
    public static func open(
        data: Data,
        limits: ArchiveLimits = .init(),
        tuning: ArchiveTuning = .init()
    ) async throws -> LocalComicArchive {
        let reader = try await ArchiveReader.open(data: data, limits: limits, tuning: tuning)
        return try await prepare(reader)
    }

    /// Analyzes archive entries to establish natural page ordering and pair sidecar metadata.
    private static func prepare(_ reader: ArchiveReader) async throws -> LocalComicArchive {
        do {
            let allMembers = try await reader.listing()

            // Filter out directory entries and hidden/metadata files (e.g. macOS resource forks).
            let filteredMembers = allMembers.filter { member in
                guard !member.isDirectory else { return false }
                let pathComponents = member.path.split(separator: "/")
                let containsExcludedComponent = pathComponents.contains { component in
                    (component.hasPrefix(".") && component != ".") || component == "__MACOSX"
                }
                return !containsExcludedComponent
            }

            // Natural alphanumeric ordering so "page2.jpg" comes before "page10.jpg".
            let orderedMembers = filteredMembers.sorted {
                $0.path.localizedStandardCompare($1.path) == .orderedAscending
            }

            // Select only readable image, text, or markdown page candidates.
            let selectedMembers = orderedMembers.filter { member in
                let lowercasedPath = member.path.lowercased()
                let fileExtension = URL(fileURLWithPath: lowercasedPath).pathExtension
                let isDescriptionSidecar = lowercasedPath.hasSuffix(".desc.txt")
                let isPageAsset = recognizedImageExtensions.contains(fileExtension)
                    || fileExtension == "txt"
                    || fileExtension == "md"

                return !isDescriptionSidecar && isPageAsset
            }

            guard !selectedMembers.isEmpty else {
                throw ComicArchiveError.noPages
            }

            // Map numbered description sidecars (e.g. "1.desc.txt" -> Page 1).
            var descriptions: [Int: String] = [:]
            for member in orderedMembers where member.path.lowercased().hasSuffix(".desc.txt") {
                let filename = URL(fileURLWithPath: member.path).lastPathComponent
                if let number = Int(filename.split(separator: ".").first ?? ""),
                   number > 0,
                   number <= selectedMembers.count {
                    guard descriptions[number] == nil else {
                        throw ArchiveFailure.ambiguousEntry(filename)
                    }
                    descriptions[number] = member.path
                }
            }

            let pages = selectedMembers.enumerated().map { index, member in
                let fileExtension = URL(fileURLWithPath: member.path).pathExtension.lowercased()
                let kind: ComicPage.Kind
                if fileExtension == "md" {
                    kind = .markdown
                } else if fileExtension == "txt" {
                    kind = .text
                } else {
                    kind = .image
                }

                return ComicPage(
                    path: member.path,
                    kind: kind,
                    uncompressedBytes: member.uncompressedBytes,
                    descriptionPath: descriptions[index + 1]
                )
            }

            let metadataCandidates = orderedMembers.filter {
                URL(fileURLWithPath: $0.path).lastPathComponent.lowercased() == "comicinfo.xml"
            }
            let infoMember = metadataCandidates.first(where: { $0.path == "ComicInfo.xml" }) ?? metadataCandidates.first

            return LocalComicArchive(
                reader: reader,
                pages: pages,
                comicInfoPath: infoMember?.path
            )
        } catch {
            await reader.close()
            throw error
        }
    }

    /// Reads raw uncompressed bytes for the page at the given index.
    public func bytes(at index: Int) async throws -> Data {
        guard pages.indices.contains(index) else {
            throw ComicArchiveError.invalidPageIndex
        }
        return try await reader.read(pages[index].path)
    }

    /// Reads UTF-8 text for the text or markdown page at the given index.
    public func text(at index: Int) async throws -> String {
        guard pages.indices.contains(index), pages[index].kind != .image else {
            throw ComicArchiveError.invalidPageIndex
        }
        let data = try await bytes(at: index)
        guard let textString = String(data: data, encoding: .utf8) else {
            throw ComicArchiveError.invalidText(pages[index].path)
        }
        return textString
    }

    /// Reads the companion description text for the page at the given index, if one exists.
    public func description(at index: Int) async throws -> String? {
        guard pages.indices.contains(index) else {
            throw ComicArchiveError.invalidPageIndex
        }
        guard let path = pages[index].descriptionPath else {
            return nil
        }
        guard try await reader.member(path).uncompressedBytes <= UInt64(ComicInfoCodec.maximumBytes) else {
            throw ArchiveFailure.memberTooLarge(path)
        }
        let data = try await reader.read(path)
        guard let textString = String(data: data, encoding: .utf8) else {
            throw ComicArchiveError.invalidText(path)
        }
        return textString
    }

    /// Decodes the `ComicInfo` metadata structure if present within the archive.
    public func comicInfo() async throws -> ComicInfo? {
        guard let path = comicInfoPath else {
            return nil
        }
        guard try await reader.member(path).uncompressedBytes <= UInt64(ComicInfoCodec.maximumBytes) else {
            throw ComicInfoError.tooLarge
        }
        let data = try await reader.read(path)
        return try ComicInfoCodec.decode(data)
    }

    /// Reads raw uncompressed bytes for the cover image (the first image page in the archive).
    public func coverBytes() async throws -> Data? {
        guard let coverIndex = pages.firstIndex(where: { $0.kind == .image }) else {
            return nil
        }
        return try await bytes(at: coverIndex)
    }

    /// Closes the underlying archive reader and releases open file handles.
    public func close() async {
        await reader.close()
    }
}
