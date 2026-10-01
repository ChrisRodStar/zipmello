import Foundation

/// Creation-only writer: local records first, one central directory at finish.
/// Discard the staging archive after any failure; it is not readable until finish.
public final class BulkArchiveWriter {
    private let archive: Archive
    private var records: [(Archive.LocalFileHeader, UInt64, Bool)] = []
    private let maximumBytes: UInt64
    private var finished = false

    public init(url: URL, maximumBytes: UInt64) throws {
        archive = try Archive(url: url, accessMode: .create)
        self.maximumBytes = maximumBytes
        guard fseeko(archive.archiveFile, 0, SEEK_SET) == 0 else { throw Archive.ArchiveError.unwritableArchive }
    }

    public func append(path: String, size: Int64, deflate: Bool, bufferSize: Int,
                       wholeBufferLimit: Int = 0, isDirectory: Bool = false, provider: @escaping Provider) throws {
        guard !finished, size >= 0, bufferSize > 0 else { throw Archive.ArchiveError.unwritableArchive }
        guard path.utf8.count <= Int(UInt16.max) else { throw Archive.ArchiveError.invalidEntryPath }
        // The app budgets entries below 4 GiB. Reserving ZIP64 local fields for
        // larger entries also prevents header growth when the header is patched.
        guard size < Int64(UInt32.max) else { throw Archive.ArchiveError.invalidEntrySize }
        let start = try position()
        let date = Date().fileModificationDateTime
        let method: CompressionMethod = deflate && !isDirectory ? .deflate : .none
        _ = try archive.writeLocalFileHeader(path: path, compressionMethod: method,
                    size: (UInt64(size), 0), checksum: 0, modificationDateTime: date)
        var written: UInt64 = 0
        let consume: Consumer = { chunk in
            try Task.checkCancellation()
            guard try self.position() <= self.maximumBytes,
                  UInt64(chunk.count) <= self.maximumBytes - (try self.position()) else {
                throw Archive.ArchiveError.invalidEntrySize
            }
            guard try Data.write(chunk: chunk, to: self.archive.archiveFile) == chunk.count else {
                throw Archive.ArchiveError.unwritableArchive
            }
            written += UInt64(chunk.count)
        }
        let checkedProvider: Provider = { offset, count in
            try Task.checkCancellation()
            let data = try provider(offset, count)
            guard data.count == count else { throw Archive.ArchiveError.invalidEntrySize }
            return data
        }
        let crc: UInt32
        if deflate, size > 0, size <= wholeBufferLimit {
            let input = try checkedProvider(0, Int(size))
            let output = try WholeBufferDeflate.compress(input)
            try consume(output)
            crc = input.crc32(checksum: 0)
        } else if deflate {
            crc = try Data.compress(size: size, bufferSize: bufferSize, provider: checkedProvider, consumer: consume)
        } else {
            crc = try Data.consumePart(of: size, chunkSize: bufferSize, skipCRC32: false,
                                      provider: checkedProvider, consumer: consume)
        }
        let end = try position()
        guard written < UInt32.max else { throw Archive.ArchiveError.invalidEntrySize }
        try seek(start)
        let header = try archive.writeLocalFileHeader(path: path, compressionMethod: method,
                    size: (UInt64(size), written), checksum: crc, modificationDateTime: date)
        try seek(end)
        records.append((header, start, isDirectory))
        try checkSize()
    }

    public func finish() throws {
        guard !finished else { throw Archive.ArchiveError.unwritableArchive }
        try Task.checkCancellation()
        let directoryStart = try position()
        for (header, offset, directory) in records {
            try Task.checkCancellation()
            _ = try archive.writeCentralDirectoryStructure(localFileHeader: header,
                relativeOffset: offset, externalFileAttributes: FileManager.externalFileAttributesForEntry(of: directory ? .directory : .file, permissions: directory ? 0o755 : 0o644))
            try checkSize()
        }
        let directoryEnd = try position()
        let count = UInt64(records.count)
        let size = directoryEnd - directoryStart
        let zip64 = count >= UInt16.max || size >= UInt32.max || directoryStart >= UInt32.max
        if zip64 {
            archive.zip64EndOfCentralDirectory = try archive.writeZIP64EOCD(totalNumberOfEntries: count,
                sizeOfCentralDirectory: size, offsetOfCentralDirectory: directoryStart,
                offsetOfEndOfCentralDirectory: directoryEnd)
        }
        let record = Archive.EndOfCentralDirectoryRecord(record: archive.endOfCentralDirectoryRecord,
            numberOfEntriesOnDisk: count >= UInt16.max ? .max : UInt16(count),
            numberOfEntriesInCentralDirectory: count >= UInt16.max ? .max : UInt16(count),
            updatedSizeOfCentralDirectory: size >= UInt32.max ? .max : UInt32(size),
            startOfCentralDirectory: directoryStart >= UInt32.max ? .max : UInt32(directoryStart))
        guard try Data.write(chunk: record.data, to: archive.archiveFile) == record.data.count,
              fflush(archive.archiveFile) == 0 else { throw Archive.ArchiveError.unwritableArchive }
        archive.endOfCentralDirectoryRecord = record
        try checkSize()
        finished = true
        records.removeAll()
    }

    private func position() throws -> UInt64 {
        let offset = ftello(archive.archiveFile)
        guard offset >= 0 else { throw Archive.ArchiveError.unwritableArchive }
        return UInt64(offset)
    }
    private func seek(_ offset: UInt64) throws {
        guard offset <= Int64.max, fseeko(archive.archiveFile, Int64(offset), SEEK_SET) == 0 else {
            throw Archive.ArchiveError.unwritableArchive
        }
    }
    private func checkSize() throws {
        guard try position() <= maximumBytes else { throw Archive.ArchiveError.invalidEntrySize }
    }
}
