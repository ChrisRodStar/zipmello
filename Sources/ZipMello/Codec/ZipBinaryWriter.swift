import Foundation
import SystemPackage

/// High-speed native binary stream writer for ZIP and CBZ creation.
struct ZipBinaryWriter {
    struct WrittenEntry {
        let path: String
        let compressionMethod: UInt16
        let crc32: UInt32
        let compressedSize: UInt64
        let uncompressedSize: UInt64
        let localHeaderOffset: UInt64
        let isDirectory: Bool
    }

    /// Creates a complete ZIP archive from a list of assets at a staging location.
    static func writeArchive(
        to stagingURL: URL,
        assets: [ArchiveAsset],
        sizes: [UInt64],
        limits: ArchiveLimits,
        tuning: ArchiveTuning,
        progress: ArchiveProgressHandler?,
        totalBytes: UInt64
    ) throws {
        let handle = try FileHandle(forWritingTo: stagingURL)
        defer { try? handle.close() }

        var writtenEntries: [WrittenEntry] = []
        writtenEntries.reserveCapacity(assets.count)

        var currentOffset: UInt64 = 0
        var processedBytes: UInt64 = 0

        for (asset, uncompressedSize) in zip(assets, sizes) {
            try Task.checkCancellation()

            let isDirectory: Bool
            if case .directory = asset.content { isDirectory = true } else { isDirectory = false }
            let path = asset.path
            let nameData = Data(path.utf8)
            let method: UInt16 = isDirectory ? 0 : (asset.compression == .deflate ? 8 : 0)

            let localHeaderOffset = currentOffset
            let headerSize: UInt64 = 30 + UInt64(nameData.count)

            // Buffer local header space (sizes and CRC updated after payload streaming)
            var localHeaderBuffer = Data(count: Int(headerSize))
            localHeaderBuffer.withUnsafeMutableBytes { buffer in
                ZipBinaryBuffer.writeUInt32(ZipMagic.localHeader, into: buffer, offset: 0)
                ZipBinaryBuffer.writeUInt16(20, into: buffer, offset: 4) // Version needed
                ZipBinaryBuffer.writeUInt16(0x0800, into: buffer, offset: 6)  // Flags (Bit 11 = UTF-8)
                ZipBinaryBuffer.writeUInt16(method, into: buffer, offset: 8) // Method
                ZipBinaryBuffer.writeUInt16(0, into: buffer, offset: 10) // Mod time
                ZipBinaryBuffer.writeUInt16(0, into: buffer, offset: 12) // Mod date
                ZipBinaryBuffer.writeUInt32(0, into: buffer, offset: 14) // CRC (placeholder)
                ZipBinaryBuffer.writeUInt32(0, into: buffer, offset: 18) // Compressed size (placeholder)
                ZipBinaryBuffer.writeUInt32(0, into: buffer, offset: 22) // Uncompressed size (placeholder)
                ZipBinaryBuffer.writeUInt16(UInt16(nameData.count), into: buffer, offset: 26)
                ZipBinaryBuffer.writeUInt16(0, into: buffer, offset: 28)
            }
            nameData.withUnsafeBytes { nameBuffer in
                localHeaderBuffer.replaceSubrange(30..<Int(headerSize), with: nameBuffer)
            }

            try handle.write(contentsOf: localHeaderBuffer)
            currentOffset += headerSize

            var payloadBytes: UInt64 = 0
            var crc: UInt32 = 0

            if !isDirectory {
                switch asset.content {
                case .directory:
                    break

                case .bytes(let data):
                    if method == 8 { // DEFLATE
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
                    } else { // Stored
                        crc = ZipChecksum.update(data: data)
                        try handle.write(contentsOf: data)
                        payloadBytes = UInt64(data.count)
                    }

                case .file(let fileURL):
                    let descriptor = try FileDescriptor.open(fileURL.path, .readOnly, options: [.noFollow])
                    defer { try? descriptor.close() }

                    if method == 8 { // DEFLATE
                        crc = try ZipDeflateEngine.compress(
                            uncompressedBytes: uncompressedSize,
                            bufferBytes: limits.bufferBytes,
                            provider: { offset, count in
                                let buf = UnsafeMutableRawBufferPointer.allocate(byteCount: count, alignment: 8)
                                defer { buf.deallocate() }
                                let read = try descriptor.read(fromAbsoluteOffset: Int64(offset), into: buf)
                                guard read > 0 else { return Data() }
                                return Data(bytes: buf.baseAddress!, count: read)
                            },
                            consumer: { chunk in
                                try handle.write(contentsOf: chunk)
                                payloadBytes += UInt64(chunk.count)
                            }
                        )
                    } else { // Stored
                        var readPos: UInt64 = 0
                        let chunkBuf = UnsafeMutableRawBufferPointer.allocate(byteCount: limits.bufferBytes, alignment: 8)
                        defer { chunkBuf.deallocate() }

                        while readPos < uncompressedSize {
                            try Task.checkCancellation()
                            let toRead = Int(Swift.min(UInt64(limits.bufferBytes), uncompressedSize - readPos))
                            let slice = UnsafeMutableRawBufferPointer(rebasing: chunkBuf[0..<toRead])
                            let read = try descriptor.read(fromAbsoluteOffset: Int64(readPos), into: slice)
                            guard read > 0 else { break }
                            let readData = Data(bytes: slice.baseAddress!, count: read)
                            crc = ZipChecksum.update(current: crc, data: readData)
                            try handle.write(contentsOf: readData)
                            payloadBytes += UInt64(read)
                            readPos += UInt64(read)
                        }
                    }
                }

                currentOffset += payloadBytes

                // Overwrite local header with true CRC and sizes
                try handle.seek(toOffset: localHeaderOffset + 14)
                var patchBuffer = Data(count: 12)
                patchBuffer.withUnsafeMutableBytes { patchPtr in
                    ZipBinaryBuffer.writeUInt32(crc, into: patchPtr, offset: 0)
                    ZipBinaryBuffer.writeUInt32(UInt32(Swift.min(payloadBytes, UInt64(UInt32.max))), into: patchPtr, offset: 4)
                    ZipBinaryBuffer.writeUInt32(UInt32(Swift.min(uncompressedSize, UInt64(UInt32.max))), into: patchPtr, offset: 8)
                }
                try handle.write(contentsOf: patchBuffer)
                try handle.seek(toOffset: currentOffset)
            }

            writtenEntries.append(WrittenEntry(
                path: path,
                compressionMethod: method,
                crc32: crc,
                compressedSize: payloadBytes,
                uncompressedSize: uncompressedSize,
                localHeaderOffset: localHeaderOffset,
                isDirectory: isDirectory
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

        // Write Central Directory Records
        let centralDirectoryStartOffset = currentOffset

        for entry in writtenEntries {
            let pathData = Data(entry.path.utf8)
            let cdRecordSize = 46 + pathData.count
            var cdBuffer = Data(count: cdRecordSize)

            cdBuffer.withUnsafeMutableBytes { buffer in
                ZipBinaryBuffer.writeUInt32(ZipMagic.centralDirectoryHeader, into: buffer, offset: 0)
                ZipBinaryBuffer.writeUInt16(20, into: buffer, offset: 4) // Version made by
                ZipBinaryBuffer.writeUInt16(20, into: buffer, offset: 6) // Version needed
                ZipBinaryBuffer.writeUInt16(0x0800, into: buffer, offset: 8)  // General flags (Bit 11 = UTF-8)
                ZipBinaryBuffer.writeUInt16(entry.compressionMethod, into: buffer, offset: 10)
                ZipBinaryBuffer.writeUInt16(0, into: buffer, offset: 12) // Mod time
                ZipBinaryBuffer.writeUInt16(0, into: buffer, offset: 14) // Mod date
                ZipBinaryBuffer.writeUInt32(entry.crc32, into: buffer, offset: 16)
                ZipBinaryBuffer.writeUInt32(UInt32(Swift.min(entry.compressedSize, UInt64(UInt32.max))), into: buffer, offset: 20)
                ZipBinaryBuffer.writeUInt32(UInt32(Swift.min(entry.uncompressedSize, UInt64(UInt32.max))), into: buffer, offset: 24)
                ZipBinaryBuffer.writeUInt16(UInt16(pathData.count), into: buffer, offset: 28)
                ZipBinaryBuffer.writeUInt16(0, into: buffer, offset: 30) // Extra len
                ZipBinaryBuffer.writeUInt16(0, into: buffer, offset: 32) // Comment len
                ZipBinaryBuffer.writeUInt16(0, into: buffer, offset: 34) // Disk start
                ZipBinaryBuffer.writeUInt16(0, into: buffer, offset: 36) // Internal attrs
                ZipBinaryBuffer.writeUInt32(entry.isDirectory ? 0x10 : 0, into: buffer, offset: 38) // External attrs
                ZipBinaryBuffer.writeUInt32(UInt32(Swift.min(entry.localHeaderOffset, UInt64(UInt32.max))), into: buffer, offset: 42)
            }

            pathData.withUnsafeBytes { nameBuffer in
                cdBuffer.replaceSubrange(46..<cdRecordSize, with: nameBuffer)
            }

            try handle.write(contentsOf: cdBuffer)
            currentOffset += UInt64(cdRecordSize)
        }

        let centralDirectorySize = currentOffset - centralDirectoryStartOffset

        let isZip64 = writtenEntries.count >= 0xFFFF || centralDirectoryStartOffset >= 0xFFFFFFFF || centralDirectorySize >= 0xFFFFFFFF

        if isZip64 {
            let zip64EOCDOffset = currentOffset
            var zip64EOCDBuf = Data(count: 56)
            zip64EOCDBuf.withUnsafeMutableBytes { buffer in
                ZipBinaryBuffer.writeUInt32(ZipMagic.zip64EOCDRecord, into: buffer, offset: 0)
                ZipBinaryBuffer.writeUInt64(44, into: buffer, offset: 4) // Size after record length field
                ZipBinaryBuffer.writeUInt16(45, into: buffer, offset: 12) // Version made by
                ZipBinaryBuffer.writeUInt16(45, into: buffer, offset: 14) // Version needed
                ZipBinaryBuffer.writeUInt32(0, into: buffer, offset: 16) // Disk num
                ZipBinaryBuffer.writeUInt32(0, into: buffer, offset: 20) // Disk start
                ZipBinaryBuffer.writeUInt64(UInt64(writtenEntries.count), into: buffer, offset: 24)
                ZipBinaryBuffer.writeUInt64(UInt64(writtenEntries.count), into: buffer, offset: 32)
                ZipBinaryBuffer.writeUInt64(centralDirectorySize, into: buffer, offset: 40)
                ZipBinaryBuffer.writeUInt64(centralDirectoryStartOffset, into: buffer, offset: 48)
            }
            try handle.write(contentsOf: zip64EOCDBuf)
            currentOffset += 56

            var locatorBuf = Data(count: 20)
            locatorBuf.withUnsafeMutableBytes { buffer in
                ZipBinaryBuffer.writeUInt32(ZipMagic.zip64EOCDLocator, into: buffer, offset: 0)
                ZipBinaryBuffer.writeUInt32(0, into: buffer, offset: 4) // Disk start
                ZipBinaryBuffer.writeUInt64(zip64EOCDOffset, into: buffer, offset: 8)
                ZipBinaryBuffer.writeUInt32(1, into: buffer, offset: 16) // Total disks
            }
            try handle.write(contentsOf: locatorBuf)
            currentOffset += 20
        }

        // Write End of Central Directory (EOCD) Record
        var eocdBuffer = Data(count: 22)
        eocdBuffer.withUnsafeMutableBytes { buffer in
            ZipBinaryBuffer.writeUInt32(ZipMagic.endOfCentralDirectory, into: buffer, offset: 0)
            ZipBinaryBuffer.writeUInt16(0, into: buffer, offset: 4) // Disk num
            ZipBinaryBuffer.writeUInt16(0, into: buffer, offset: 6) // Start disk
            ZipBinaryBuffer.writeUInt16(isZip64 ? 0xFFFF : UInt16(writtenEntries.count), into: buffer, offset: 8)
            ZipBinaryBuffer.writeUInt16(isZip64 ? 0xFFFF : UInt16(writtenEntries.count), into: buffer, offset: 10)
            ZipBinaryBuffer.writeUInt32(isZip64 ? 0xFFFFFFFF : UInt32(centralDirectorySize), into: buffer, offset: 12)
            ZipBinaryBuffer.writeUInt32(isZip64 ? 0xFFFFFFFF : UInt32(centralDirectoryStartOffset), into: buffer, offset: 16)
            ZipBinaryBuffer.writeUInt16(0, into: buffer, offset: 20) // Comment length
        }
        try handle.write(contentsOf: eocdBuffer)
    }
}
