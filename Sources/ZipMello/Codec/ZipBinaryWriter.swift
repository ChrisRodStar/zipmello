import Foundation
import SystemPackage
import zlib

/// High-speed native binary stream writer for ZIP and CBZ archive creation.
///
/// Implements PKWARE APPNOTE.TXT binary layouts:
/// - Section 4.3.7: Local file header format (30 bytes + filename)
/// - Section 4.3.12: Central directory header format (46 bytes + filename)
/// - Section 4.3.14: ZIP64 End of Central Directory Record (56 bytes)
/// - Section 4.3.15: ZIP64 End of Central Directory Locator (20 bytes)
/// - Section 4.3.16: End of Central Directory Record (22 bytes)
struct ZipBinaryWriter {
    /// Tracks the physical extent; header patches do not consume the append budget twice.
    private final class Output {
        let handle: FileHandle
        let maximumBytes: UInt64
        var offset: UInt64 = 0

        init(url: URL, maximumBytes: UInt64) throws {
            handle = try FileHandle(forWritingTo: url)
            self.maximumBytes = maximumBytes
        }
        func write(contentsOf data: Data) throws {
            try Task.checkCancellation()
            guard offset <= maximumBytes, UInt64(data.count) <= maximumBytes - offset else {
                throw ArchiveFailure.archiveTooLarge
            }
            try handle.write(contentsOf: data)
            offset += UInt64(data.count)
        }
        func seek(toOffset position: UInt64) throws {
            try handle.seek(toOffset: position)
            offset = position
        }
        func close() throws { try handle.close() }
    }

    /// In-flight metadata captured while streaming entries, used to construct central directory records.
    struct WrittenEntry: Sendable {
        let path: String
        let compressionMethod: UInt16
        let crc32: UInt32
        let compressedSize: UInt64
        let uncompressedSize: UInt64
        let localHeaderOffset: UInt64
        let isDirectory: Bool
        var usesZIP64: Bool = false
    }

    /// Serializes assets sequentially into a staging file at `stagingURL`.
    ///
    /// - Parameters:
    ///   - stagingURL: Local file URL where bytes are written.
    ///   - assets: Ordered archive assets to stream.
    ///   - sizes: Pre-validated uncompressed sizes corresponding to each asset.
    ///   - limits: Resource limits governing memory and buffer sizing.
    ///   - tuning: Buffer size and compression level configurations.
    ///   - progress: Optional progress reporting callback.
    ///   - totalBytes: Pre-computed sum of uncompressed entry sizes.
    static func writeArchive(
        to stagingURL: URL,
        assets: [ArchiveAsset],
        sizes: [UInt64],
        limits: ArchiveLimits,
        tuning: ArchiveTuning,
        progress: ArchiveProgressHandler?,
        totalBytes: UInt64
    ) throws {
        let handle = try Output(url: stagingURL, maximumBytes: limits.maximumArchiveBytes)
        defer {
            try? handle.close()
        }

        var writtenEntries: [WrittenEntry] = []
        writtenEntries.reserveCapacity(assets.count)

        var currentOffset: UInt64 = 0
        var processedBytes: UInt64 = 0

        for (asset, uncompressedSize) in zip(assets, sizes) {
            try Task.checkCancellation()

            let isDirectory: Bool
            if case .directory = asset.content {
                isDirectory = true
            } else {
                isDirectory = false
            }

            let path = asset.path
            let nameData = Data(path.utf8)
            let method: UInt16 = isDirectory ? 0 : (asset.compression == .deflate ? 8 : 0)

            let localHeaderOffset = currentOffset
            let usesZIP64 = requiresZIP64LocalHeader(size: uncompressedSize, method: method)

            // 1. Write initial Local File Header with zeroed size/CRC placeholders.
            let headerSize = try writeLocalFileHeader(
                handle: handle,
                nameData: nameData,
                method: method,
                zip64: usesZIP64
            )
            currentOffset += headerSize

            var payloadBytes: UInt64 = 0
            var crc: UInt32 = 0

            // 2. Stream entry payload and calculate CRC32 checksum.
            if !isDirectory {
                (payloadBytes, crc) = try streamPayload(
                    handle: handle,
                    asset: asset,
                    uncompressedSize: uncompressedSize,
                    method: method,
                    limits: limits
                )
                currentOffset += payloadBytes

                // 3. Patch the local file header with final CRC and byte lengths.
                try patchLocalFileHeader(
                    handle: handle,
                    localHeaderOffset: localHeaderOffset,
                    crc: crc,
                    payloadBytes: payloadBytes,
                    uncompressedSize: uncompressedSize,
                    currentOffset: currentOffset,
                    nameLength: nameData.count,
                    zip64: usesZIP64
                )
            }

            writtenEntries.append(WrittenEntry(
                path: path,
                compressionMethod: method,
                crc32: crc,
                compressedSize: payloadBytes,
                uncompressedSize: uncompressedSize,
                localHeaderOffset: localHeaderOffset,
                isDirectory: isDirectory,
                usesZIP64: usesZIP64
            ))

            processedBytes += uncompressedSize
            if let progress = progress {
                progress(ArchiveProgress(
                    completedBytes: processedBytes,
                    totalBytes: totalBytes,
                    completedEntries: writtenEntries.count,
                    totalEntries: assets.count
                ))
            }
        }

        // 4. Write Central Directory Records.
        let centralDirectoryStartOffset = currentOffset
        let centralDirectoryBytesWritten = try writeCentralDirectoryRecords(
            handle: handle,
            entries: writtenEntries
        )
        currentOffset += centralDirectoryBytesWritten

        let centralDirectorySize = centralDirectoryBytesWritten

        // Determine if ZIP64 format is necessary (counts >= 65535 or sizes >= 4GB).
        let isZip64 = writtenEntries.contains { $0.usesZIP64 }
            || writtenEntries.count >= 0xFFFF
            || centralDirectoryStartOffset >= 0xFFFFFFFF
            || centralDirectorySize >= 0xFFFFFFFF

        // 5. Emit ZIP64 EOCD Record and Locator if needed.
        if isZip64 {
            let zip64BytesWritten = try writeZIP64EOCD(
                handle: handle,
                entryCount: UInt64(writtenEntries.count),
                centralDirectorySize: centralDirectorySize,
                centralDirectoryStartOffset: centralDirectoryStartOffset,
                currentOffset: currentOffset
            )
            currentOffset += zip64BytesWritten
        }

        // 6. Write standard End of Central Directory record.
        try writeStandardEOCD(
            handle: handle,
            entryCount: writtenEntries.count,
            centralDirectorySize: centralDirectorySize,
            centralDirectoryStartOffset: centralDirectoryStartOffset,
            isZip64: isZip64
        )
    }

    // MARK: - Modular Serialization Helpers

    /// Emits a local file header into the stream with placeholder sizes and checksum.
    ///
    /// APPNOTE.TXT Section 4.3.7: 30 bytes fixed header followed by filename bytes.
    private static func writeLocalFileHeader(
        handle: Output,
        nameData: Data,
        method: UInt16,
        zip64: Bool
    ) throws -> UInt64 {
        let localHeaderBuffer = localFileHeader(nameData: nameData, method: method, zip64: zip64)
        try handle.write(contentsOf: localHeaderBuffer)
        return UInt64(localHeaderBuffer.count)
    }

    static func requiresZIP64LocalHeader(size: UInt64, method: UInt16) -> Bool {
        if size >= UInt64(UInt32.max) { return true }
        // Reserve extended size fields before streaming if compressed output might reach the sentinel.
        return method == 8 && compressBound(uLong(size)) >= UInt32.max
    }

    static func localFileHeader(nameData: Data, method: UInt16, zip64: Bool) -> Data {
        let headerSize = 30 + nameData.count + (zip64 ? 20 : 0)
        var localHeaderBuffer = Data(count: headerSize)

        localHeaderBuffer.withUnsafeMutableBytes { buffer in
            ZipBinaryBuffer.writeUInt32(ZipMagic.localHeader, into: buffer, offset: 0)
            ZipBinaryBuffer.writeUInt16(zip64 ? 45 : 20, into: buffer, offset: 4) // Version needed
            ZipBinaryBuffer.writeUInt16(0x0800, into: buffer, offset: 6)  // General purpose flags: Bit 11 = UTF-8
            ZipBinaryBuffer.writeUInt16(method, into: buffer, offset: 8)  // Compression method (0 or 8)
            ZipBinaryBuffer.writeUInt16(0, into: buffer, offset: 10)     // Last mod time
            ZipBinaryBuffer.writeUInt16(0, into: buffer, offset: 12)     // Last mod date
            ZipBinaryBuffer.writeUInt32(0, into: buffer, offset: 14)     // CRC-32 (placeholder)
            ZipBinaryBuffer.writeUInt32(zip64 ? UInt32.max : 0, into: buffer, offset: 18)     // Compressed size (placeholder)
            ZipBinaryBuffer.writeUInt32(zip64 ? UInt32.max : 0, into: buffer, offset: 22)     // Uncompressed size (placeholder)
            ZipBinaryBuffer.writeUInt16(UInt16(nameData.count), into: buffer, offset: 26)
            ZipBinaryBuffer.writeUInt16(zip64 ? 20 : 0, into: buffer, offset: 28)
            if zip64 {
                let extraOffset = 30 + nameData.count
                ZipBinaryBuffer.writeUInt16(ZipMagic.zip64ExtraFieldTag, into: buffer, offset: extraOffset)
                ZipBinaryBuffer.writeUInt16(16, into: buffer, offset: extraOffset + 2)
            }
        }

        nameData.withUnsafeBytes { nameBuffer in
            localHeaderBuffer.replaceSubrange(30..<(30 + nameData.count), with: nameBuffer)
        }

        return localHeaderBuffer
    }

    /// Streams member data (either memory buffer or file descriptor) into the archive, computing CRC32.
    private static func streamPayload(
        handle: Output,
        asset: ArchiveAsset,
        uncompressedSize: UInt64,
        method: UInt16,
        limits: ArchiveLimits
    ) throws -> (payloadBytes: UInt64, crc: UInt32) {
        var payloadBytes: UInt64 = 0
        var crc: UInt32 = 0

        switch asset.content {
        case .directory:
            break

        case .bytes(let data):
            if method == 8 {
                crc = try ZipDeflateEngine.compress(
                    uncompressedBytes: UInt64(data.count),
                    bufferBytes: limits.bufferBytes,
                    provider: { offset, count in
                        let start = data.startIndex + Int(offset)
                        return data.subdata(in: start..<(start + count))
                    },
                    consumer: { chunk in
                        try handle.write(contentsOf: chunk)
                        payloadBytes += UInt64(chunk.count)
                    }
                )
            } else {
                crc = ZipChecksum.update(data: data)
                try handle.write(contentsOf: data)
                payloadBytes = UInt64(data.count)
            }

        case .file(let fileURL):
            let descriptor = try FileDescriptor.open(fileURL.path, .readOnly, options: [.noFollow])
            defer {
                try? descriptor.close()
            }
            let identity = try ArchiveFileIdentity(fileDescriptor: descriptor.rawValue)
            guard UInt64(identity.bytes) == uncompressedSize else {
                throw ArchiveFailure.invalidSource("Source size changed: \(asset.path)")
            }

            if method == 8 {
                crc = try ZipDeflateEngine.compress(
                    uncompressedBytes: uncompressedSize,
                    bufferBytes: limits.bufferBytes,
                    provider: { offset, count in
                        let buf = UnsafeMutableRawBufferPointer.allocate(byteCount: count, alignment: 8)
                        defer { buf.deallocate() }
                        let bytesRead = try descriptor.read(fromAbsoluteOffset: Int64(offset), into: buf)
                        guard bytesRead > 0 else { return Data() }
                        return Data(bytes: buf.baseAddress!, count: bytesRead)
                    },
                    consumer: { chunk in
                        try handle.write(contentsOf: chunk)
                        payloadBytes += UInt64(chunk.count)
                    }
                )
            } else {
                var readOffset: UInt64 = 0
                let chunkBuf = UnsafeMutableRawBufferPointer.allocate(byteCount: limits.bufferBytes, alignment: 8)
                defer { chunkBuf.deallocate() }

                while readOffset < uncompressedSize {
                    try Task.checkCancellation()
                    let toRead = Int(Swift.min(UInt64(limits.bufferBytes), uncompressedSize - readOffset))
                    let slice = UnsafeMutableRawBufferPointer(rebasing: chunkBuf[0..<toRead])
                    let bytesRead = try descriptor.read(fromAbsoluteOffset: Int64(readOffset), into: slice)
                    guard bytesRead > 0 else {
                        throw ArchiveFailure.invalidSource("Truncated source: \(asset.path)")
                    }

                    let readData = Data(bytes: slice.baseAddress!, count: bytesRead)
                    crc = ZipChecksum.update(current: crc, data: readData)
                    try handle.write(contentsOf: readData)
                    payloadBytes += UInt64(bytesRead)
                    readOffset += UInt64(bytesRead)
                }
            }
            guard identity.matches(fileDescriptor: descriptor.rawValue), identity.matches(url: fileURL) else {
                throw ArchiveFailure.invalidSource("Source changed during write: \(asset.path)")
            }
        }

        return (payloadBytes, crc)
    }

    /// Rewrites the local file header with final calculated CRC32 and byte sizes.
    private static func patchLocalFileHeader(
        handle: Output,
        localHeaderOffset: UInt64,
        crc: UInt32,
        payloadBytes: UInt64,
        uncompressedSize: UInt64,
        currentOffset: UInt64,
        nameLength: Int,
        zip64: Bool
    ) throws {
        try handle.seek(toOffset: localHeaderOffset + 14)

        var patchBuffer = Data(count: 12)
        patchBuffer.withUnsafeMutableBytes { patchPtr in
            ZipBinaryBuffer.writeUInt32(crc, into: patchPtr, offset: 0)
            ZipBinaryBuffer.writeUInt32(zip64 ? UInt32.max : UInt32(payloadBytes), into: patchPtr, offset: 4)
            ZipBinaryBuffer.writeUInt32(zip64 ? UInt32.max : UInt32(uncompressedSize), into: patchPtr, offset: 8)
        }

        try handle.write(contentsOf: patchBuffer)
        if zip64 {
            var sizes = Data(count: 16)
            sizes.withUnsafeMutableBytes { buffer in
                ZipBinaryBuffer.writeUInt64(uncompressedSize, into: buffer, offset: 0)
                ZipBinaryBuffer.writeUInt64(payloadBytes, into: buffer, offset: 8)
            }
            try handle.seek(toOffset: localHeaderOffset + 30 + UInt64(nameLength) + 4)
            try handle.write(contentsOf: sizes)
        }
        try handle.seek(toOffset: currentOffset)
    }

    /// Writes all central directory headers into the archive.
    ///
    /// APPNOTE.TXT Section 4.3.12: 46 bytes fixed structure followed by member filename.
    private static func writeCentralDirectoryRecords(
        handle: Output,
        entries: [WrittenEntry]
    ) throws -> UInt64 {
        var totalBytesWritten: UInt64 = 0
        for entry in entries {
            let record = centralDirectoryRecord(entry)
            try handle.write(contentsOf: record)
            totalBytesWritten += UInt64(record.count)
        }
        return totalBytesWritten
    }

    static func centralDirectoryRecord(_ entry: WrittenEntry) -> Data {
        let pathData = Data(entry.path.utf8)
        let expanded64 = entry.usesZIP64 || entry.uncompressedSize >= UInt64(UInt32.max)
        let compressed64 = entry.usesZIP64 || entry.compressedSize >= UInt64(UInt32.max)
        let offset64 = entry.localHeaderOffset >= UInt64(UInt32.max)
        let valueCount = (expanded64 ? 1 : 0) + (compressed64 ? 1 : 0) + (offset64 ? 1 : 0)
        let extraLength = valueCount == 0 ? 0 : 4 + valueCount * 8
        var record = Data(count: 46 + pathData.count + extraLength)
        record.withUnsafeMutableBytes { buffer in
            ZipBinaryBuffer.writeUInt32(ZipMagic.centralDirectoryHeader, into: buffer, offset: 0)
            ZipBinaryBuffer.writeUInt16(extraLength > 0 ? 45 : 20, into: buffer, offset: 4)
            ZipBinaryBuffer.writeUInt16(extraLength > 0 ? 45 : 20, into: buffer, offset: 6)
            ZipBinaryBuffer.writeUInt16(0x0800, into: buffer, offset: 8)
            ZipBinaryBuffer.writeUInt16(entry.compressionMethod, into: buffer, offset: 10)
            ZipBinaryBuffer.writeUInt32(entry.crc32, into: buffer, offset: 16)
            ZipBinaryBuffer.writeUInt32(compressed64 ? UInt32.max : UInt32(entry.compressedSize), into: buffer, offset: 20)
            ZipBinaryBuffer.writeUInt32(expanded64 ? UInt32.max : UInt32(entry.uncompressedSize), into: buffer, offset: 24)
            ZipBinaryBuffer.writeUInt16(UInt16(pathData.count), into: buffer, offset: 28)
            ZipBinaryBuffer.writeUInt16(UInt16(extraLength), into: buffer, offset: 30)
            ZipBinaryBuffer.writeUInt32(entry.isDirectory ? 0x10 : 0, into: buffer, offset: 38)
            ZipBinaryBuffer.writeUInt32(offset64 ? UInt32.max : UInt32(entry.localHeaderOffset), into: buffer, offset: 42)
            if extraLength > 0 {
                var offset = 46 + pathData.count
                ZipBinaryBuffer.writeUInt16(ZipMagic.zip64ExtraFieldTag, into: buffer, offset: offset)
                ZipBinaryBuffer.writeUInt16(UInt16(valueCount * 8), into: buffer, offset: offset + 2)
                offset += 4
                for (required, value) in [(expanded64, entry.uncompressedSize), (compressed64, entry.compressedSize), (offset64, entry.localHeaderOffset)] where required {
                    ZipBinaryBuffer.writeUInt64(value, into: buffer, offset: offset)
                    offset += 8
                }
            }
        }
        record.replaceSubrange(46..<(46 + pathData.count), with: pathData)
        return record
    }

    /// Emits the ZIP64 End of Central Directory Record (56 bytes) and Locator (20 bytes).
    private static func writeZIP64EOCD(
        handle: Output,
        entryCount: UInt64,
        centralDirectorySize: UInt64,
        centralDirectoryStartOffset: UInt64,
        currentOffset: UInt64
    ) throws -> UInt64 {
        let zip64EOCDOffset = currentOffset

        // APPNOTE.TXT Section 4.3.14: ZIP64 EOCD Record (56 bytes)
        var zip64EOCDBuf = Data(count: 56)
        zip64EOCDBuf.withUnsafeMutableBytes { buffer in
            ZipBinaryBuffer.writeUInt32(ZipMagic.zip64EOCDRecord, into: buffer, offset: 0)
            ZipBinaryBuffer.writeUInt64(44, into: buffer, offset: 4)     // Remaining record size after this field
            ZipBinaryBuffer.writeUInt16(45, into: buffer, offset: 12)    // Version made by (4.5 for ZIP64)
            ZipBinaryBuffer.writeUInt16(45, into: buffer, offset: 14)    // Version needed to extract
            ZipBinaryBuffer.writeUInt32(0, into: buffer, offset: 16)     // Disk number
            ZipBinaryBuffer.writeUInt32(0, into: buffer, offset: 20)     // Disk start number
            ZipBinaryBuffer.writeUInt64(entryCount, into: buffer, offset: 24) // Entries on this disk
            ZipBinaryBuffer.writeUInt64(entryCount, into: buffer, offset: 32) // Total entries
            ZipBinaryBuffer.writeUInt64(centralDirectorySize, into: buffer, offset: 40)
            ZipBinaryBuffer.writeUInt64(centralDirectoryStartOffset, into: buffer, offset: 48)
        }
        try handle.write(contentsOf: zip64EOCDBuf)

        // APPNOTE.TXT Section 4.3.15: ZIP64 EOCD Locator (20 bytes)
        var locatorBuf = Data(count: 20)
        locatorBuf.withUnsafeMutableBytes { buffer in
            ZipBinaryBuffer.writeUInt32(ZipMagic.zip64EOCDLocator, into: buffer, offset: 0)
            ZipBinaryBuffer.writeUInt32(0, into: buffer, offset: 4)      // Disk start number
            ZipBinaryBuffer.writeUInt64(zip64EOCDOffset, into: buffer, offset: 8) // Offset to ZIP64 EOCD
            ZipBinaryBuffer.writeUInt32(1, into: buffer, offset: 16)     // Total disks
        }
        try handle.write(contentsOf: locatorBuf)

        return 76 // 56 + 20
    }

    /// Emits the standard End of Central Directory (EOCD) record.
    ///
    /// APPNOTE.TXT Section 4.3.16: Fixed 22 bytes structure.
    private static func writeStandardEOCD(
        handle: Output,
        entryCount: Int,
        centralDirectorySize: UInt64,
        centralDirectoryStartOffset: UInt64,
        isZip64: Bool
    ) throws {
        var eocdBuffer = Data(count: 22)
        eocdBuffer.withUnsafeMutableBytes { buffer in
            ZipBinaryBuffer.writeUInt32(ZipMagic.endOfCentralDirectory, into: buffer, offset: 0)
            ZipBinaryBuffer.writeUInt16(0, into: buffer, offset: 4)     // Disk number
            ZipBinaryBuffer.writeUInt16(0, into: buffer, offset: 6)     // Disk where CD starts
            ZipBinaryBuffer.writeUInt16(isZip64 ? 0xFFFF : UInt16(entryCount), into: buffer, offset: 8)
            ZipBinaryBuffer.writeUInt16(isZip64 ? 0xFFFF : UInt16(entryCount), into: buffer, offset: 10)
            ZipBinaryBuffer.writeUInt32(isZip64 ? 0xFFFFFFFF : UInt32(centralDirectorySize), into: buffer, offset: 12)
            ZipBinaryBuffer.writeUInt32(isZip64 ? 0xFFFFFFFF : UInt32(centralDirectoryStartOffset), into: buffer, offset: 16)
            ZipBinaryBuffer.writeUInt16(0, into: buffer, offset: 20)    // Comment length
        }
        try handle.write(contentsOf: eocdBuffer)
    }
}
