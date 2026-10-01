import Foundation

/// Immutable metadata; contains no archive cursor or mutable handle.
public struct ArchiveReadDescriptor: Sendable {
    public let offset: UInt64
    public let compressedBytes: UInt64
    public let expandedBytes: UInt64
    public let checksum: UInt32
    public let isDeflated: Bool
}

extension Archive {
    public var declaredEntryCount: UInt64 { totalNumberOfEntriesInCentralDirectory }
    public func descriptor(for entry: Entry) throws -> ArchiveReadDescriptor {
        guard entry.type == .file,
              !entry.centralDirectoryStructure.isEncrypted,
              entry.localFileHeader.compressionMethod == entry.centralDirectoryStructure.compressionMethod,
              let method = CompressionMethod(rawValue: entry.localFileHeader.compressionMethod) else {
            throw ArchiveError.invalidCompressionMethod
        }
        if entry.centralDirectoryStructure.usesDataDescriptor {
            guard entry.checksum == entry.centralDirectoryStructure.crc32,
                  entry.compressedSize == entry.centralDirectoryStructure.effectiveCompressedSize,
                  entry.uncompressedSize == entry.centralDirectoryStructure.effectiveUncompressedSize else {
                throw ArchiveError.invalidEntrySize
            }
        }
        guard method == .deflate || entry.compressedSize == entry.uncompressedSize else {
            throw ArchiveError.invalidEntrySize
        }
        return .init(offset: entry.dataOffset, compressedBytes: entry.compressedSize,
                     expandedBytes: entry.uncompressedSize, checksum: entry.checksum, isDeflated: method == .deflate)
    }

    /// The provider performs positional reads, so extraction never mutates a shared seek cursor.
    public static func extract(_ descriptor: ArchiveReadDescriptor, bufferSize: Int,
                               wholeBufferLimit: Int = 0, provider: Provider, consumer: Consumer) throws -> UInt32 {
        guard descriptor.compressedBytes <= Int64.max, bufferSize > 0 else { throw ArchiveError.invalidEntrySize }
        if descriptor.isDeflated, wholeBufferLimit > 0,
           descriptor.expandedBytes <= wholeBufferLimit, descriptor.compressedBytes <= wholeBufferLimit {
            let input = try provider(0, Int(descriptor.compressedBytes))
            let output = try WholeBufferDeflate.decompress(input, expandedBytes: Int(descriptor.expandedBytes))
            try consumer(output)
            return output.crc32(checksum: 0)
        }
        if descriptor.isDeflated {
            return try Data.decompress(size: Int64(descriptor.compressedBytes), bufferSize: bufferSize,
                skipCRC32: false, provider: provider, consumer: consumer)
        }
        return try Data.consumePart(of: Int64(descriptor.expandedBytes), chunkSize: bufferSize,
                                    skipCRC32: false, provider: provider, consumer: consumer)
    }
}
