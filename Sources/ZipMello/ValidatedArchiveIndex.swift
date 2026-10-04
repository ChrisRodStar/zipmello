import Foundation

/// Validated index of archive members ensuring safe parsing, memory reservation, and traversal checks.
///
/// `ValidatedArchiveIndex` processes central directory records produced by `ZipCentralDirectoryParser`,
/// verifying that entry offsets, compressed sizes, and uncompressed allocations satisfy strict security bounds.
struct ValidatedArchiveIndex: Sendable {
    /// Fast random-access lookup map indexed by member path.
    var index: [String: ArchiveReadDescriptor] = [:]

    /// Natural archive-ordered member manifest.
    var members: [ArchiveMember] = []

    /// Constructs a validated index from parsed central directory headers.
    ///
    /// - Parameters:
    ///   - parser: Central directory parser containing the decoded End of Central Directory record.
    ///   - input: Underlying binary archive stream.
    ///   - bytes: Total physical byte length of the archive file or buffer.
    ///   - limits: Resource and security limits.
    /// - Throws: `ArchiveFailure` if the directory is truncated, forged, or exceeds size bounds.
    init(
        parser: ZipCentralDirectoryParser,
        input: ArchiveInput,
        bytes: UInt64,
        limits: ArchiveLimits
    ) throws {
        var expandedBytes: UInt64 = 0
        var seenPaths = Set<String>()
        let entryCount = parser.eocd.totalEntries

        guard entryCount <= UInt64(limits.maximumEntries) else {
            throw ArchiveFailure.tooManyEntries
        }

        // APPNOTE.TXT Section 4.3.12: Each central directory header requires at least 46 physical
        // bytes (fixed header structure without filename/extra fields). An archive claiming more
        // entries than bytes / 46 is structurally impossible. Enforcing this check before calling
        // reserveCapacity prevents memory exhaustion attacks from forged entry counts.
        guard entryCount <= bytes / 46 else {
            throw ArchiveFailure.invalidSource("Incomplete directory")
        }

        index.reserveCapacity(Int(entryCount))
        members.reserveCapacity(Int(entryCount))
        seenPaths.reserveCapacity(Int(entryCount))

        for entry in parser.entries {
            try Task.checkCancellation()

            guard members.count < limits.maximumEntries else {
                throw ArchiveFailure.tooManyEntries
            }
            guard !entry.isSymlink else {
                throw ArchiveFailure.unsupportedEntry(entry.path)
            }

            let path = entry.path
            _ = try ArchivePath.canonical(path, directory: entry.isDirectory)

            guard seenPaths.insert(path).inserted else {
                throw ArchiveFailure.duplicatePath(path)
            }
            guard entry.uncompressedSize <= limits.maximumEntryBytes else {
                throw ArchiveFailure.memberTooLarge(path)
            }

            let (sum, overflow) = expandedBytes.addingReportingOverflow(entry.uncompressedSize)
            guard !overflow, sum <= limits.maximumExpandedBytes else {
                throw ArchiveFailure.expandedArchiveTooLarge
            }
            expandedBytes = sum

            if !entry.isDirectory {
                let offset = try ZipCentralDirectoryParser.payloadOffset(for: entry, input: input)
                guard offset <= bytes, entry.compressedSize <= bytes - offset else {
                    throw ArchiveFailure.invalidSource(path)
                }

                let method: ArchiveCompression
                switch entry.compressionMethod {
                case 0:
                    method = .stored
                case 8:
                    method = .deflate
                default:
                    throw ArchiveFailure.unsupportedEntry("Compression method \(entry.compressionMethod) for '\(path)'")
                }
                let descriptor = ArchiveReadDescriptor(
                    offset: offset,
                    compressedBytes: entry.compressedSize,
                    expandedBytes: entry.uncompressedSize,
                    checksum: entry.crc32,
                    compression: method
                )
                index[path] = descriptor
            }

            members.append(ArchiveMember(
                path: path,
                uncompressedBytes: entry.uncompressedSize,
                compressedBytes: entry.compressedSize,
                isDirectory: entry.isDirectory
            ))
        }

        guard UInt64(members.count) == entryCount else {
            throw ArchiveFailure.invalidSource("Incomplete directory")
        }
    }
}
