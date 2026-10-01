import Foundation
import ZipMello

public enum ComicArchiveError: Error, Equatable { case noPages, invalidText(String), invalidPageIndex }
public struct ComicPage: Sendable, Equatable {
    public enum Kind: Sendable { case image, text, markdown }
    public let path: String
    public let kind: Kind
    public let uncompressedBytes: UInt64
    public let descriptionPath: String?
}

/// Lazy CBZ/ZIP adapter. Image decoding, chapter identities and database ownership stay in Melloku.
public struct LocalComicArchive: Sendable {
    private let reader: ArchiveReader
    public let pages: [ComicPage]
    public let comicInfoPath: String?
    private static let images: Set<String> = ["jpg", "jpeg", "png", "webp", "gif", "heic", "avif"]
    public static func open(_ url: URL, limits: ArchiveLimits = .init(), tuning: ArchiveTuning = .init()) async throws -> Self {
        try await prepare(try await ArchiveReader.open(url, limits: limits, tuning: tuning))
    }
    public static func open(data: Data, limits: ArchiveLimits = .init(), tuning: ArchiveTuning = .init()) async throws -> Self {
        try await prepare(try await ArchiveReader.open(data: data, limits: limits, tuning: tuning))
    }
    private static func prepare(_ reader: ArchiveReader) async throws -> Self {
        do {
            let members = try await reader.listing().filter { member in
                !member.isDirectory && !member.path.split(separator: "/").contains { $0.hasPrefix(".") && $0 != "." || $0 == "__MACOSX" }
            }
            let ordered = members.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            let selected = ordered.filter { member in
                let lower = member.path.lowercased(), ext = URL(fileURLWithPath: lower).pathExtension
                return !lower.hasSuffix(".desc.txt") && (images.contains(ext) || ext == "txt" || ext == "md")
            }
            guard !selected.isEmpty else { throw ComicArchiveError.noPages }
            var descriptions: [Int: String] = [:]
            for member in ordered where member.path.lowercased().hasSuffix(".desc.txt") {
                let name = URL(fileURLWithPath: member.path).lastPathComponent
                if let number = Int(name.split(separator: ".").first ?? ""), number > 0, number <= selected.count {
                    guard descriptions[number] == nil else { throw ArchiveFailure.ambiguousEntry(name) }
                    descriptions[number] = member.path
                }
            }
            let pages = selected.enumerated().map { index, member in
                let ext = URL(fileURLWithPath: member.path).pathExtension.lowercased()
                return ComicPage(path: member.path, kind: ext == "md" ? .markdown : ext == "txt" ? .text : .image,
                    uncompressedBytes: member.uncompressedBytes, descriptionPath: descriptions[index + 1])
            }
            let metadata = ordered.filter { URL(fileURLWithPath: $0.path).lastPathComponent.lowercased() == "comicinfo.xml" }
            let info = metadata.first(where: { $0.path == "ComicInfo.xml" }) ?? metadata.first
            return Self(reader: reader, pages: pages, comicInfoPath: info?.path)
        } catch { await reader.close(); throw error }
    }
    public func bytes(at index: Int) async throws -> Data {
        guard pages.indices.contains(index) else { throw ComicArchiveError.invalidPageIndex }
        return try await reader.read(pages[index].path)
    }
    public func text(at index: Int) async throws -> String {
        guard pages.indices.contains(index), pages[index].kind != .image else { throw ComicArchiveError.invalidPageIndex }
        guard let text = String(data: try await bytes(at: index), encoding: .utf8) else { throw ComicArchiveError.invalidText(pages[index].path) }
        return text
    }
    public func description(at index: Int) async throws -> String? {
        guard pages.indices.contains(index) else { throw ComicArchiveError.invalidPageIndex }
        guard let path = pages[index].descriptionPath else { return nil }
        guard try await reader.member(path).uncompressedBytes <= UInt64(ComicInfoCodec.maximumBytes) else { throw ArchiveFailure.memberTooLarge(path) }
        guard let text = String(data: try await reader.read(path), encoding: .utf8) else { throw ComicArchiveError.invalidText(path) }
        return text
    }
    public func comicInfo() async throws -> ComicInfo? {
        guard let path = comicInfoPath else { return nil }
        guard try await reader.member(path).uncompressedBytes <= UInt64(ComicInfoCodec.maximumBytes) else { throw ComicInfoError.tooLarge }
        return try ComicInfoCodec.decode(await reader.read(path))
    }
    public func coverBytes() async throws -> Data? {
        guard let index = pages.firstIndex(where: { $0.kind == .image }) else { return nil }
        return try await bytes(at: index)
    }
    public func close() async { await reader.close() }
}
