import Foundation

/// Fast scanner and central directory parser for ZIP and ZIP64 archives.
struct ZipCentralDirectoryParser: Sendable {
    let eocd: ZipEOCD
    let entries: [ZipCentralEntry]

    /// Parses an archive input source (file or memory data).
    static func parse(input: ArchiveInput) throws -> ZipCentralDirectoryParser {
        let totalBytes = input.count
        guard totalBytes >= 22 else {
            throw ArchiveFailure.invalidSource("Archive size too small for ZIP header")
        }

        // Step 1: Scan tail for EOCD record signature (0x06054b50)
        let maxSearchSize = Int(Swift.min(totalBytes, 65557)) // 22 bytes EOCD + 65535 max comment
        let tailOffset = totalBytes - UInt64(maxSearchSize)
        let tailData = try input.read(offset: tailOffset, count: maxSearchSize)

        var eocdOffsetInTail = -1
        tailData.withUnsafeBytes { buffer in
            for i in stride(from: buffer.count - 22, through: 0, by: -1) {
                if ZipBinaryBuffer.readUInt32(from: buffer, offset: i) == ZipMagic.endOfCentralDirectory {
                    let commentLen = Int(ZipBinaryBuffer.readUInt16(from: buffer, offset: i + 20))
                    if i + 22 + commentLen == buffer.count {
                        eocdOffsetInTail = i
                        break
                    }
                }
            }
            if eocdOffsetInTail < 0 {
                for i in stride(from: buffer.count - 22, through: 0, by: -1) {
                    if ZipBinaryBuffer.readUInt32(from: buffer, offset: i) == ZipMagic.endOfCentralDirectory {
                        let commentLen = Int(ZipBinaryBuffer.readUInt16(from: buffer, offset: i + 20))
                        if i + 22 + commentLen <= buffer.count {
                            eocdOffsetInTail = i
                            break
                        }
                    }
                }
            }
        }

        guard eocdOffsetInTail >= 0 else {
            throw ArchiveFailure.invalidSource("Missing End of Central Directory record")
        }

        let eocdAbsoluteOffset = tailOffset + UInt64(eocdOffsetInTail)
        let eocd = tailData.withUnsafeBytes { buffer -> ZipEOCD in
            let diskNum = ZipBinaryBuffer.readUInt16(from: buffer, offset: eocdOffsetInTail + 4)
            let startDisk = ZipBinaryBuffer.readUInt16(from: buffer, offset: eocdOffsetInTail + 6)
            let diskEntries = UInt64(ZipBinaryBuffer.readUInt16(from: buffer, offset: eocdOffsetInTail + 8))
            let totalEntries = UInt64(ZipBinaryBuffer.readUInt16(from: buffer, offset: eocdOffsetInTail + 10))
            let cdSize = UInt64(ZipBinaryBuffer.readUInt32(from: buffer, offset: eocdOffsetInTail + 12))
            let cdOffset = UInt64(ZipBinaryBuffer.readUInt32(from: buffer, offset: eocdOffsetInTail + 16))
            let commentLen = ZipBinaryBuffer.readUInt16(from: buffer, offset: eocdOffsetInTail + 20)

            return ZipEOCD(
                diskNumber: diskNum,
                startDisk: startDisk,
                diskEntries: diskEntries,
                totalEntries: totalEntries,
                centralDirectorySize: cdSize,
                centralDirectoryOffset: cdOffset,
                commentLength: commentLen
            )
        }

        // Step 2: Check for ZIP64 EOCD Locator before EOCD
        var finalEOCD = eocd
        if eocdAbsoluteOffset >= 20 {
            let locatorOffset = eocdAbsoluteOffset - 20
            let locatorData = try input.read(offset: locatorOffset, count: 20)
            let isZip64Locator = locatorData.withUnsafeBytes { buffer in
                ZipBinaryBuffer.readUInt32(from: buffer, offset: 0) == ZipMagic.zip64EOCDLocator
            }

            if isZip64Locator {
                let zip64EOCDOffset = locatorData.withUnsafeBytes { buffer in
                    ZipBinaryBuffer.readUInt64(from: buffer, offset: 8)
                }
                if zip64EOCDOffset < totalBytes {
                    let zip64EOCDData = try input.read(offset: zip64EOCDOffset, count: 56)
                    finalEOCD = zip64EOCDData.withUnsafeBytes { buffer in
                        guard ZipBinaryBuffer.readUInt32(from: buffer, offset: 0) == ZipMagic.zip64EOCDRecord else {
                            return eocd
                        }
                        let diskNum = ZipBinaryBuffer.readUInt16(from: buffer, offset: 16)
                        let startDisk = ZipBinaryBuffer.readUInt16(from: buffer, offset: 20)
                        let diskEntries = ZipBinaryBuffer.readUInt64(from: buffer, offset: 24)
                        let totalEntries = ZipBinaryBuffer.readUInt64(from: buffer, offset: 32)
                        let cdSize = ZipBinaryBuffer.readUInt64(from: buffer, offset: 40)
                        let cdOffset = ZipBinaryBuffer.readUInt64(from: buffer, offset: 48)

                        return ZipEOCD(
                            diskNumber: diskNum,
                            startDisk: startDisk,
                            diskEntries: diskEntries,
                            totalEntries: totalEntries,
                            centralDirectorySize: cdSize,
                            centralDirectoryOffset: cdOffset,
                            commentLength: eocd.commentLength
                        )
                    }
                }
            }
        }

        // Step 3: Parse Central Directory entries
        guard finalEOCD.centralDirectoryOffset <= totalBytes,
              finalEOCD.centralDirectorySize <= totalBytes - finalEOCD.centralDirectoryOffset else {
            throw ArchiveFailure.invalidSource("Central directory offset extends beyond archive")
        }

        let cdData = try input.read(offset: finalEOCD.centralDirectoryOffset, count: Int(finalEOCD.centralDirectorySize))
        var entries: [ZipCentralEntry] = []
        entries.reserveCapacity(Int(finalEOCD.totalEntries))

        try cdData.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            var offset = 0
            while offset + 46 <= buffer.count {
                let magic = ZipBinaryBuffer.readUInt32(from: buffer, offset: offset)
                guard magic == ZipMagic.centralDirectoryHeader else { break }

                let versionMadeBy = ZipBinaryBuffer.readUInt16(from: buffer, offset: offset + 4)
                let versionNeeded = ZipBinaryBuffer.readUInt16(from: buffer, offset: offset + 6)
                let generalFlags = ZipBinaryBuffer.readUInt16(from: buffer, offset: offset + 8)
                let method = ZipBinaryBuffer.readUInt16(from: buffer, offset: offset + 10)
                let modTime = ZipBinaryBuffer.readUInt16(from: buffer, offset: offset + 12)
                let modDate = ZipBinaryBuffer.readUInt16(from: buffer, offset: offset + 14)
                let crc = ZipBinaryBuffer.readUInt32(from: buffer, offset: offset + 16)
                var compSize = UInt64(ZipBinaryBuffer.readUInt32(from: buffer, offset: offset + 20))
                var uncompSize = UInt64(ZipBinaryBuffer.readUInt32(from: buffer, offset: offset + 24))
                let nameLen = Int(ZipBinaryBuffer.readUInt16(from: buffer, offset: offset + 28))
                let extraLen = Int(ZipBinaryBuffer.readUInt16(from: buffer, offset: offset + 30))
                let commentLen = Int(ZipBinaryBuffer.readUInt16(from: buffer, offset: offset + 32))
                let diskStart = ZipBinaryBuffer.readUInt32(from: buffer, offset: offset + 34)
                let intAttrs = ZipBinaryBuffer.readUInt16(from: buffer, offset: offset + 36)
                let extAttrs = ZipBinaryBuffer.readUInt32(from: buffer, offset: offset + 38)
                var localOffset = UInt64(ZipBinaryBuffer.readUInt32(from: buffer, offset: offset + 42))

                let recordTotalLen = 46 + nameLen + extraLen + commentLen
                guard offset + recordTotalLen <= buffer.count else {
                    throw ArchiveFailure.invalidSource("Truncated central directory record")
                }

                let nameBytes = buffer[offset + 46 ..< offset + 46 + nameLen]
                let isUTF8 = (generalFlags & 0x0800) != 0
                let cp437Encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(0x0411))
                let pathStr: String
                if isUTF8 {
                    pathStr = String(bytes: nameBytes, encoding: .utf8) ?? String(decoding: nameBytes, as: UTF8.self)
                } else if let validUTF8 = String(bytes: nameBytes, encoding: .utf8) {
                    pathStr = validUTF8
                } else {
                    pathStr = String(bytes: nameBytes, encoding: cp437Encoding) ?? String(decoding: nameBytes, as: UTF8.self)
                }

                // Inspect ZIP64 extra field if 32-bit values are 0xFFFFFFFF
                let extraOffset = offset + 46 + nameLen
                var extraIdx = 0
                while extraIdx + 4 <= extraLen {
                    let tag = ZipBinaryBuffer.readUInt16(from: buffer, offset: extraOffset + extraIdx)
                    let size = Int(ZipBinaryBuffer.readUInt16(from: buffer, offset: extraOffset + extraIdx + 2))
                    if tag == ZipMagic.zip64ExtraFieldTag {
                        var fieldPos = extraOffset + extraIdx + 4
                        let fieldEnd = fieldPos + size
                        if uncompSize == 0xFFFFFFFF && fieldPos + 8 <= fieldEnd {
                            uncompSize = ZipBinaryBuffer.readUInt64(from: buffer, offset: fieldPos)
                            fieldPos += 8
                        }
                        if compSize == 0xFFFFFFFF && fieldPos + 8 <= fieldEnd {
                            compSize = ZipBinaryBuffer.readUInt64(from: buffer, offset: fieldPos)
                            fieldPos += 8
                        }
                        if localOffset == 0xFFFFFFFF && fieldPos + 8 <= fieldEnd {
                            localOffset = ZipBinaryBuffer.readUInt64(from: buffer, offset: fieldPos)
                        }
                        break
                    }
                    extraIdx += 4 + size
                }

                let posixMode = (extAttrs >> 16) & 0xF000
                let isSymlink = posixMode == 0xA000
                let isDirectory = pathStr.hasSuffix("/") || posixMode == 0x4000 || (extAttrs & 0x10 != 0)
                entries.append(ZipCentralEntry(
                    versionMadeBy: versionMadeBy,
                    versionNeeded: versionNeeded,
                    generalPurposeFlags: generalFlags,
                    compressionMethod: method,
                    lastModTime: modTime,
                    lastModDate: modDate,
                    crc32: crc,
                    compressedSize: compSize,
                    uncompressedSize: uncompSize,
                    filenameLength: UInt16(nameLen),
                    extraFieldLength: UInt16(extraLen),
                    commentLength: UInt16(commentLen),
                    diskNumberStart: diskStart,
                    internalAttributes: intAttrs,
                    externalAttributes: extAttrs,
                    localHeaderOffset: localOffset,
                    path: pathStr,
                    isDirectory: isDirectory,
                    isSymlink: isSymlink
                ))

                offset += recordTotalLen
            }
        }

        return ZipCentralDirectoryParser(eocd: finalEOCD, entries: entries)
    }

    /// Inspects the local header at `entry.localHeaderOffset` to calculate the exact payload byte offset.
    static func payloadOffset(for entry: ZipCentralEntry, input: ArchiveInput) throws -> UInt64 {
        let localHeaderData = try input.read(offset: entry.localHeaderOffset, count: 30)
        return try localHeaderData.withUnsafeBytes { buffer in
            guard ZipBinaryBuffer.readUInt32(from: buffer, offset: 0) == ZipMagic.localHeader else {
                throw ArchiveFailure.invalidSource("Missing local header signature for \(entry.path)")
            }
            let nameLen = UInt64(ZipBinaryBuffer.readUInt16(from: buffer, offset: 26))
            let extraLen = UInt64(ZipBinaryBuffer.readUInt16(from: buffer, offset: 28))
            return entry.localHeaderOffset + 30 + nameLen + extraLen
        }
    }
}
