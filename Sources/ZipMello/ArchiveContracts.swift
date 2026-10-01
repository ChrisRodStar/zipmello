import Foundation

public enum ArchiveFailure: Error, Equatable, Sendable {
    case sessionCapacityExceeded
    case invalidLimits
    case unsafePath(String)
    case duplicatePath(String)
    case unsupportedEntry(String)
    case tooManyEntries
    case archiveTooLarge
    case memberTooLarge(String)
    case expandedArchiveTooLarge
    case ambiguousEntry(String)
    case destinationCollision(String)
    case cacheCapacityExceeded
    case missingEntry(String)
    case checksumMismatch(String)
    case sizeMismatch(String)
    case closed
    case destinationExists
    case invalidSource(String)
}

/// Immutable metadata for an indexed member read operation.
public struct ArchiveReadDescriptor: Sendable {
    public let offset: UInt64
    public let compressedBytes: UInt64
    public let expandedBytes: UInt64
    public let checksum: UInt32
    public let compression: ArchiveCompression

    public var isDeflated: Bool { compression == .deflate }

    public init(offset: UInt64, compressedBytes: UInt64, expandedBytes: UInt64, checksum: UInt32, compression: ArchiveCompression) {
        self.offset = offset
        self.compressedBytes = compressedBytes
        self.expandedBytes = expandedBytes
        self.checksum = checksum
        self.compression = compression
    }
}

/// Budgets apply both to declared sizes and bytes actually emitted by extraction.
public struct ArchiveLimits: Sendable {
    public var maximumArchiveBytes: UInt64
    public var maximumEntryBytes: UInt64
    public var maximumExpandedBytes: UInt64
    public var maximumEntries: Int
    public var bufferBytes: Int

    public init(maximumArchiveBytes: UInt64 = 512 * 1_024 * 1_024,
                maximumEntryBytes: UInt64 = 250 * 1_024 * 1_024,
                maximumExpandedBytes: UInt64 = 2 * 1_024 * 1_024 * 1_024,
                maximumEntries: Int = 20_000, bufferBytes: Int = 64 * 1_024) {
        self.maximumArchiveBytes = maximumArchiveBytes
        self.maximumEntryBytes = maximumEntryBytes
        self.maximumExpandedBytes = maximumExpandedBytes
        self.maximumEntries = maximumEntries
        self.bufferBytes = bufferBytes
    }

    /// Existing Melloku remote-page contracts use decimal byte limits.
    public static var sourcePages: Self {
        .init(maximumArchiveBytes: 64_000_000, maximumEntryBytes: 32_000_000,
              maximumExpandedBytes: 64_000_000)
    }
    public static var sourcePackages: Self {
        .init(maximumArchiveBytes: 64_000_000, maximumEntryBytes: 64_000_000,
              maximumExpandedBytes: 64_000_000)
    }
    /// Opt-in profiles for installations; never use these for remote page responses.
    public static var dictionaries: Self {
        .init(maximumArchiveBytes: 2 * 1_024 * 1_024 * 1_024,
              maximumEntryBytes: 512 * 1_024 * 1_024,
              maximumExpandedBytes: 8 * 1_024 * 1_024 * 1_024, maximumEntries: 200_000)
    }
    public static var models: Self {
        .init(maximumArchiveBytes: 4 * 1_024 * 1_024 * 1_024,
              maximumEntryBytes: 2 * 1_024 * 1_024 * 1_024,
              maximumExpandedBytes: 8 * 1_024 * 1_024 * 1_024, maximumEntries: 50_000)
    }

    /// Release sweeps favor larger chunks when exporting page/model files.
    public static var exporting: Self { .init(bufferBytes: 256 * 1_024) }

    func validate() throws {
        guard maximumArchiveBytes > 0, maximumEntryBytes > 0, maximumEntryBytes <= UInt64(Int.max),
              maximumExpandedBytes > 0, maximumEntries > 0,
              bufferBytes > 0, bufferBytes <= 4 * 1_024 * 1_024 else {
            throw ArchiveFailure.invalidLimits
        }
    }
}

public struct ArchiveMember: Sendable, Equatable {
    public let path: String
    public let uncompressedBytes: UInt64
    public let compressedBytes: UInt64
    public let isDirectory: Bool
}

/// Bounded experiments are opt-in; zero keeps Apple streaming compression.
public struct ArchiveTuning: Sendable {
    public var bypassFileCache: Bool
    public var readConcurrency: Int
    public var wholeBufferDeflateLimit: Int
    public init(readConcurrency: Int = 1, wholeBufferDeflateLimit: Int = 0, bypassFileCache: Bool = false) {
        self.bypassFileCache = bypassFileCache
        self.readConcurrency = readConcurrency
        self.wholeBufferDeflateLimit = wholeBufferDeflateLimit
    }
    /// Opt in when issuing bounded page prefetch requests.
    public static var pagePrefetch: Self { .init(readConcurrency: 4) }
    /// Use only for consumers whose entries fit this bounded whole-buffer path.
    public static var smallEntries: Self { .init(wholeBufferDeflateLimit: 4 * 1_024 * 1_024) }

    func validate() throws {
        guard (1...4).contains(readConcurrency), (0...4_194_304).contains(wholeBufferDeflateLimit) else {
            throw ArchiveFailure.invalidLimits
        }
    }
}

public enum ArchiveDurability: Sendable { case buffered, synchronized }

public enum ArchiveLookup: Sendable { case exact, compatible }

/// Synchronous callbacks execute on an archive worker. Hop to the UI at a throttled rate.
public struct ArchiveProgress: Sendable, Equatable {
    public let completedBytes: UInt64
    public let totalBytes: UInt64
    public let completedEntries: Int
    public let totalEntries: Int
    public init(completedBytes: UInt64, totalBytes: UInt64, completedEntries: Int, totalEntries: Int) {
        self.completedBytes = completedBytes; self.totalBytes = totalBytes
        self.completedEntries = completedEntries; self.totalEntries = totalEntries
    }
}
public typealias ArchiveProgressHandler = @Sendable (ArchiveProgress) -> Void

public enum ArchiveCompression: Sendable { case stored, deflate }

public struct ArchiveAsset: Sendable {
    public enum Content: Sendable { case bytes(Data), file(URL), directory }
    public let path: String
    public let content: Content
    public let compression: ArchiveCompression

    public init(path: String, content: Content, compression: ArchiveCompression = .stored) {
        self.path = path
        self.content = content
        self.compression = compression
    }
}

enum ArchivePath {
    static func canonical(_ path: String, directory: Bool = false) throws -> String {
        var value = path
        while value.hasPrefix("./") { value.removeFirst(2) }
        if directory && !path.isEmpty && (value.isEmpty || value == ".") { return "" }
        try validate(value, directory: directory)
        return directory && value.hasSuffix("/") ? String(value.dropLast()) : value
    }
    static func alias(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping.lowercased()
    }
    static func validate(_ path: String, directory: Bool = false) throws {
        let value = directory && path.hasSuffix("/") ? String(path.dropLast()) : path
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard path.utf8.count <= Int(UInt16.max), !value.isEmpty, !value.hasPrefix("/"), !value.contains("\\"),
              !value.contains("\0"), !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
              !(parts.first?.contains(":") ?? false) else {
            throw ArchiveFailure.unsafePath(path)
        }
    }
}
