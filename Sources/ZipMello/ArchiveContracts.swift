import Foundation

/// Specific failure conditions encountered during archive validation, reading, extraction, or creation.
public enum ArchiveFailure: Error, Equatable, Sendable, LocalizedError, CustomStringConvertible {
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

    public var description: String {
        errorDescription ?? "Archive failure"
    }

    public var errorDescription: String? {
        switch self {
        case .sessionCapacityExceeded:
            return "The archive session pool capacity was exceeded."
        case .invalidLimits:
            return "The configured archive limits or tuning options are invalid."
        case .unsafePath(let path):
            return "The archive path '\(path)' violates security constraints (path traversal, absolute prefix, or illegal characters)."
        case .duplicatePath(let path):
            return "The archive contains duplicate entries for path '\(path)'."
        case .unsupportedEntry(let path):
            return "The archive entry '\(path)' uses an unsupported format, feature, or symbolic link."
        case .tooManyEntries:
            return "The archive exceeds the maximum allowed entry count limit."
        case .archiveTooLarge:
            return "The archive file exceeds the maximum allowed archive size limit."
        case .memberTooLarge(let path):
            return "The entry '\(path)' exceeds the maximum allowed individual entry size limit."
        case .expandedArchiveTooLarge:
            return "The total uncompressed size of all entries exceeds the maximum expanded archive limit."
        case .ambiguousEntry(let path):
            return "Multiple archive entries match the requested path alias '\(path)'."
        case .destinationCollision(let path):
            return "Extracting '\(path)' would collide with an existing or previously planned file on case-insensitive filesystems."
        case .cacheCapacityExceeded:
            return "The memory page store or cache capacity limit was exceeded."
        case .missingEntry(let path):
            return "The entry '\(path)' was not found in the archive."
        case .checksumMismatch(let path):
            return "CRC32 checksum validation failed for entry '\(path)'."
        case .sizeMismatch(let path):
            return "Decompressed size mismatch for entry '\(path)'."
        case .closed:
            return "The archive reader has been closed and cannot accept new operations."
        case .destinationExists:
            return "The destination file or directory already exists."
        case .invalidSource(let message):
            return "Invalid archive source: \(message)."
        }
    }

    public var failureReason: String? {
        switch self {
        case .unsafePath(let path):
            return "Path '\(path)' contains illegal components such as '..', '\\', null bytes, or absolute path indicators."
        case .checksumMismatch(let path):
            return "The computed CRC32 for '\(path)' did not match the recorded checksum in the central directory."
        case .destinationExists:
            return "ZipMello will not overwrite an existing destination file or directory."
        default:
            return errorDescription
        }
    }
}

/// Immutable metadata for an indexed member read operation.
public struct ArchiveReadDescriptor: Sendable {
    public let offset: UInt64
    public let compressedBytes: UInt64
    public let expandedBytes: UInt64
    public let checksum: UInt32
    public let compression: ArchiveCompression

    public var isDeflated: Bool {
        compression == .deflate
    }

    public init(
        offset: UInt64,
        compressedBytes: UInt64,
        expandedBytes: UInt64,
        checksum: UInt32,
        compression: ArchiveCompression
    ) {
        self.offset = offset
        self.compressedBytes = compressedBytes
        self.expandedBytes = expandedBytes
        self.checksum = checksum
        self.compression = compression
    }
}

/// Resource budgets and security bounds applied to both declared sizes and bytes actually emitted by extraction.
public struct ArchiveLimits: Sendable {
    public var maximumArchiveBytes: UInt64
    public var maximumEntryBytes: UInt64
    public var maximumExpandedBytes: UInt64
    public var maximumEntries: Int
    public var bufferBytes: Int

    /// Standard limits for general-purpose archive operations (512 MB archive, 250 MB member, 2 GB expanded, 20,000 entries).
    public init(
        maximumArchiveBytes: UInt64 = 512 * 1_024 * 1_024,
        maximumEntryBytes: UInt64 = 250 * 1_024 * 1_024,
        maximumExpandedBytes: UInt64 = 2 * 1_024 * 1_024 * 1_024,
        maximumEntries: Int = 20_000,
        bufferBytes: Int = 64 * 1_024
    ) {
        self.maximumArchiveBytes = maximumArchiveBytes
        self.maximumEntryBytes = maximumEntryBytes
        self.maximumExpandedBytes = maximumExpandedBytes
        self.maximumEntries = maximumEntries
        self.bufferBytes = bufferBytes
    }

    /// Profile for bounded in-memory image or page extraction (64 MB archive, 32 MB member).
    public static var sourcePages: Self {
        .init(
            maximumArchiveBytes: 64_000_000,
            maximumEntryBytes: 32_000_000,
            maximumExpandedBytes: 64_000_000
        )
    }

    /// Profile for small package downloads (64 MB archive, 64 MB member).
    public static var sourcePackages: Self {
        .init(
            maximumArchiveBytes: 64_000_000,
            maximumEntryBytes: 64_000_000,
            maximumExpandedBytes: 64_000_000
        )
    }

    /// Profile for dictionary and glossary archives (2 GB archive, 512 MB member, 8 GB expanded, 200,000 entries).
    public static var dictionaries: Self {
        .init(
            maximumArchiveBytes: 2 * 1_024 * 1_024 * 1_024,
            maximumEntryBytes: 512 * 1_024 * 1_024,
            maximumExpandedBytes: 8 * 1_024 * 1_024 * 1_024,
            maximumEntries: 200_000
        )
    }

    /// Profile for large machine learning weights or data packages (4 GB archive, 2 GB member, 8 GB expanded, 50,000 entries).
    public static var models: Self {
        .init(
            maximumArchiveBytes: 4 * 1_024 * 1_024 * 1_024,
            maximumEntryBytes: 2 * 1_024 * 1_024 * 1_024,
            maximumExpandedBytes: 8 * 1_024 * 1_024 * 1_024,
            maximumEntries: 50_000
        )
    }

    /// Optimized for high-throughput disk writes with 256 KB streaming buffers.
    public static var exporting: Self {
        .init(bufferBytes: 256 * 1_024)
    }

    /// Verifies that all limit values are within valid operational ranges.
    func validate() throws {
        guard maximumArchiveBytes > 0,
              maximumEntryBytes > 0,
              maximumEntryBytes <= UInt64(Int.max),
              maximumExpandedBytes > 0,
              maximumEntries > 0,
              bufferBytes > 0,
              bufferBytes <= 4 * 1_024 * 1_024 else {
            throw ArchiveFailure.invalidLimits
        }
    }
}

/// Metadata describing an archive entry parsed from the central directory.
public struct ArchiveMember: Sendable, Equatable {
    public let path: String
    public let uncompressedBytes: UInt64
    public let compressedBytes: UInt64
    public let isDirectory: Bool

    public init(path: String, uncompressedBytes: UInt64, compressedBytes: UInt64, isDirectory: Bool) {
        self.path = path
        self.uncompressedBytes = uncompressedBytes
        self.compressedBytes = compressedBytes
        self.isDirectory = isDirectory
    }
}

/// Concurrency tuning and read lane configuration for an archive session.
public struct ArchiveTuning: Sendable {
    public var bypassFileCache: Bool
    public var readConcurrency: Int
    public var wholeBufferDeflateLimit: Int

    public init(readConcurrency: Int = 1, wholeBufferDeflateLimit: Int = 0, bypassFileCache: Bool = false) {
        self.bypassFileCache = bypassFileCache
        self.readConcurrency = readConcurrency
        self.wholeBufferDeflateLimit = wholeBufferDeflateLimit
    }

    /// Four parallel read lanes optimized for prefetching pages or assets across multiple tasks.
    public static var pagePrefetch: Self {
        .init(readConcurrency: 4, wholeBufferDeflateLimit: 4 * 1_024 * 1_024)
    }

    /// Single-pass decompression for entries fitting within 4 MB.
    public static var smallEntries: Self {
        .init(wholeBufferDeflateLimit: 4 * 1_024 * 1_024)
    }

    func validate() throws {
        guard (1...4).contains(readConcurrency), (0...4_194_304).contains(wholeBufferDeflateLimit) else {
            throw ArchiveFailure.invalidLimits
        }
    }
}

/// Durability guarantee for disk write operations.
public enum ArchiveDurability: Sendable {
    /// Normal buffered write; relies on operating system page cache.
    case buffered
    /// Synchronizes changes to disk using `fsync` before reporting completion.
    case synchronized
}

/// Lookup matching policy for archive member paths.
public enum ArchiveLookup: Sendable {
    /// Exact case and character match.
    case exact
    /// Case-insensitive, Unicode-normalized compatible matching.
    case compatible
}

/// Progress telemetry emitted periodically during extraction or creation.
public struct ArchiveProgress: Sendable, Equatable {
    public let completedBytes: UInt64
    public let totalBytes: UInt64
    public let completedEntries: Int
    public let totalEntries: Int

    public var fractionCompleted: Double {
        totalBytes > 0 ? Swift.min(1.0, Double(completedBytes) / Double(totalBytes)) : 1.0
    }

    public init(completedBytes: UInt64, totalBytes: UInt64, completedEntries: Int, totalEntries: Int) {
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
        self.completedEntries = completedEntries
        self.totalEntries = totalEntries
    }
}

public typealias ArchiveProgressHandler = @Sendable (ArchiveProgress) -> Void

/// Compression codec method applied to an archive member.
public enum ArchiveCompression: Sendable {
    /// Uncompressed (PKZIP method 0).
    case stored
    /// Raw DEFLATE compression (PKZIP method 8).
    case deflate
}

/// Input asset payload for archive creation.
public struct ArchiveAsset: Sendable {
    public enum Content: Sendable {
        case bytes(Data)
        case file(URL)
        case directory
    }

    public let path: String
    public let content: Content
    public let compression: ArchiveCompression

    public init(path: String, content: Content, compression: ArchiveCompression = .stored) {
        self.path = path
        self.content = content
        self.compression = compression
    }
}

/// Path validation and Unicode canonicalization protecting against Zip Slip and directory traversal.
enum ArchivePath {
    /// Normalizes and validates a member path string.
    static func canonical(_ path: String, directory: Bool = false) throws -> String {
        var value = path
        while value.hasPrefix("./") {
            value.removeFirst(2)
        }
        if directory && !path.isEmpty && (value.isEmpty || value == ".") {
            return ""
        }
        try validate(value, directory: directory)
        return directory && value.hasSuffix("/") ? String(value.dropLast()) : value
    }

    /// Computes a canonical case-folded and NFC-normalized key for case-insensitive collision checks.
    static func alias(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping.lowercased()
    }

    /// Verifies that a path does not attempt path traversal, directory escape, or include illegal characters.
    static func validate(_ path: String, directory: Bool = false) throws {
        let value = directory && path.hasSuffix("/") ? String(path.dropLast()) : path
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)

        guard path.utf8.count <= Int(UInt16.max),
              !value.isEmpty,
              !value.hasPrefix("/"),
              !value.contains("\\"),
              !value.contains("\0"),
              !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
              !(parts.first?.contains(":") ?? false) else {
            throw ArchiveFailure.unsafePath(path)
        }
    }
}
