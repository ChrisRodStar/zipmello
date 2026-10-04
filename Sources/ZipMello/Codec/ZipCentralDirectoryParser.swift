import Foundation

/// High-performance scanner and central directory parser for standard and ZIP64 archives.
///
/// Implements PKWARE APPNOTE.TXT specifications:
/// - Section 4.3.16: End of central directory record (EOCD)
/// - Section 4.3.14 / 4.3.15: ZIP64 end of central directory locator and record
/// - Section 4.3.12: Central directory structure
/// - Section 4.5.3: ZIP64 extended information extra field (tag 0x0001)
/// - Appendix D: Language encoding flag (EFS) for UTF-8 and CP437 fallback
struct ZipCentralDirectoryParser: Sendable {
    let eocd: ZipEOCD
    let entries: [ZipCentralEntry]

    /// Parses an archive input source (file or memory buffer) into structured central records.
    ///
    /// - Parameter input: Binary archive input stream.
    /// - Returns: Complete parser containing the resolved EOCD and validated central entries.
    /// - Throws: `ArchiveFailure` if the archive is truncated, missing EOCD, or structurally malformed.
    static func parse(input: ArchiveInput, limits: ArchiveLimits = .init()) throws -> ZipCentralDirectoryParser {
        try limits.validate()
        let totalBytes = input.count
        guard totalBytes <= limits.maximumArchiveBytes else {
            throw ArchiveFailure.archiveTooLarge
        }
        guard totalBytes >= 22 else {
            throw ArchiveFailure.invalidSource("Archive size too small for ZIP header")
        }

        // Phase 1: Locate and parse standard End of Central Directory record.
        let (standardEOCD, eocdAbsoluteOffset) = try locateEndOfCentralDirectory(input: input, totalBytes: totalBytes)

        // Phase 2: Probe for ZIP64 EOCD Locator and Record.
        let finalEOCD = try locateZIP64EOCD(
            input: input,
            standardEOCD: standardEOCD,
            eocdAbsoluteOffset: eocdAbsoluteOffset,
            totalBytes: totalBytes
        )

        // Phase 3: Parse Central Directory entries from the determined offset.
        guard finalEOCD.centralDirectoryOffset <= totalBytes,
              finalEOCD.centralDirectorySize <= totalBytes - finalEOCD.centralDirectoryOffset else {
            throw ArchiveFailure.invalidSource("Central directory offset extends beyond archive")
        }

        guard finalEOCD.diskNumber == 0, finalEOCD.startDisk == 0,
              finalEOCD.diskEntries == finalEOCD.totalEntries else {
            throw ArchiveFailure.invalidSource("Multi-disk archives are unsupported")
        }
        guard finalEOCD.totalEntries <= UInt64(limits.maximumEntries) else {
            throw ArchiveFailure.tooManyEntries
        }
        guard finalEOCD.centralDirectorySize <= UInt64(Int.max),
              finalEOCD.totalEntries <= finalEOCD.centralDirectorySize / 46 else {
            throw ArchiveFailure.invalidSource("Incomplete directory")
        }

        let cdData = try input.read(
            offset: finalEOCD.centralDirectoryOffset,
            count: Int(finalEOCD.centralDirectorySize)
        )

        var entries: [ZipCentralEntry] = []
        entries.reserveCapacity(Int(finalEOCD.totalEntries))

        try cdData.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            var offset = 0
            while offset + 46 <= buffer.count {
                let magic = ZipBinaryBuffer.readUInt32(from: buffer, offset: offset)
                guard magic == ZipMagic.centralDirectoryHeader else { break }

                try Task.checkCancellation()
                guard entries.count < limits.maximumEntries else {
                    throw ArchiveFailure.tooManyEntries
                }
                let (entry, recordLength) = try parseCentralDirectoryRecord(buffer: buffer, offset: offset)
                entries.append(entry)
                offset += recordLength
            }
        }

        return ZipCentralDirectoryParser(eocd: finalEOCD, entries: entries)
    }

    /// Inspects the local header at `entry.localHeaderOffset` to calculate the exact payload byte offset.
    ///
    /// - Parameters:
    ///   - entry: The parsed central directory entry.
    ///   - input: Archive input source.
    /// - Returns: Absolute byte offset where the compressed or stored payload begins.
    /// - Throws: `ArchiveFailure` if the local header signature does not match.
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

    // MARK: - Private Parser Decomposition

    /// Locates the End of Central Directory record by scanning the trailing bytes of the archive.
    ///
    /// APPNOTE.TXT Section 4.3.16: EOCD is 22 bytes long plus variable comment up to 65,535 bytes.
    private static func locateEndOfCentralDirectory(
        input: ArchiveInput,
        totalBytes: UInt64
    ) throws -> (eocd: ZipEOCD, absoluteOffset: UInt64) {
        let maxSearchSize = Int(Swift.min(totalBytes, 65557))
        let tailOffset = totalBytes - UInt64(maxSearchSize)
        let tailData = try input.read(offset: tailOffset, count: maxSearchSize)

        var eocdOffsetInTail = -1

        tailData.withUnsafeBytes { buffer in
            // Fast exact match: record length + comment length equals remaining buffer bytes.
            for i in stride(from: buffer.count - 22, through: 0, by: -1) {
                if ZipBinaryBuffer.readUInt32(from: buffer, offset: i) == ZipMagic.endOfCentralDirectory {
                    let commentLen = Int(ZipBinaryBuffer.readUInt16(from: buffer, offset: i + 20))
                    if i + 22 + commentLen == buffer.count {
                        eocdOffsetInTail = i
                        break
                    }
                }
            }

            // Fallback match: tolerate trailing bytes after comment if present.
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
                diskNumber: UInt32(diskNum),
                startDisk: UInt32(startDisk),
                diskEntries: diskEntries,
                totalEntries: totalEntries,
                centralDirectorySize: cdSize,
                centralDirectoryOffset: cdOffset,
                commentLength: commentLen
            )
        }

        return (eocd, eocdAbsoluteOffset)
    }

    /// Inspects the 20 bytes preceding standard EOCD for a ZIP64 EOCD Locator and Record.
    ///
    /// APPNOTE.TXT Section 4.3.14 & 4.3.15: If the archive spans >4GB or >65535 entries,
    /// standard 32-bit fields saturate to 0xFFFFFFFF / 0xFFFF and ZIP64 headers supply 64-bit counts.
    private static func locateZIP64EOCD(
        input: ArchiveInput,
        standardEOCD: ZipEOCD,
        eocdAbsoluteOffset: UInt64,
        totalBytes: UInt64
    ) throws -> ZipEOCD {
        guard eocdAbsoluteOffset >= 20 else {
            return standardEOCD
        }

        let locatorOffset = eocdAbsoluteOffset - 20
        let locatorData = try input.read(offset: locatorOffset, count: 20)
        let isZip64Locator = locatorData.withUnsafeBytes { buffer in
            ZipBinaryBuffer.readUInt32(from: buffer, offset: 0) == ZipMagic.zip64EOCDLocator
        }

        guard isZip64Locator else {
            return standardEOCD
        }

        let zip64EOCDOffset = locatorData.withUnsafeBytes { buffer in
            ZipBinaryBuffer.readUInt64(from: buffer, offset: 8)
        }

        guard zip64EOCDOffset < totalBytes else {
            return standardEOCD
        }

        let zip64EOCDData = try input.read(offset: zip64EOCDOffset, count: 56)
        return zip64EOCDData.withUnsafeBytes { buffer in
            guard ZipBinaryBuffer.readUInt32(from: buffer, offset: 0) == ZipMagic.zip64EOCDRecord else {
                return standardEOCD
            }

            let diskNum = ZipBinaryBuffer.readUInt32(from: buffer, offset: 16)
            let startDisk = ZipBinaryBuffer.readUInt32(from: buffer, offset: 20)
            let diskEntries = ZipBinaryBuffer.readUInt64(from: buffer, offset: 24)
            let totalEntries = ZipBinaryBuffer.readUInt64(from: buffer, offset: 32)
            let cdSize = ZipBinaryBuffer.readUInt64(from: buffer, offset: 40)
            let cdOffset = ZipBinaryBuffer.readUInt64(from: buffer, offset: 48)

            return ZipEOCD(
                diskNumber: UInt32(diskNum),
                startDisk: UInt32(startDisk),
                diskEntries: diskEntries,
                totalEntries: totalEntries,
                centralDirectorySize: cdSize,
                centralDirectoryOffset: cdOffset,
                commentLength: standardEOCD.commentLength
            )
        }
    }

    /// Parses a single Central Directory record from the buffer at the given byte offset.
    ///
    /// APPNOTE.TXT Section 4.3.12: Central directory header fixed size is 46 bytes.
    private static func parseCentralDirectoryRecord(
        buffer: UnsafeRawBufferPointer,
        offset: Int
    ) throws -> (entry: ZipCentralEntry, totalLength: Int) {
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
        var diskStart = UInt32(ZipBinaryBuffer.readUInt16(from: buffer, offset: offset + 34))
        let intAttrs = ZipBinaryBuffer.readUInt16(from: buffer, offset: offset + 36)
        let extAttrs = ZipBinaryBuffer.readUInt32(from: buffer, offset: offset + 38)
        var localOffset = UInt64(ZipBinaryBuffer.readUInt32(from: buffer, offset: offset + 42))

        let recordTotalLen = 46 + nameLen + extraLen + commentLen
        guard offset + recordTotalLen <= buffer.count else {
            throw ArchiveFailure.invalidSource("Truncated central directory record")
        }

        let nameBytes = buffer[offset + 46 ..< offset + 46 + nameLen]
        let pathStr = decodeEntryPath(bytes: nameBytes, generalFlags: generalFlags)

        // APPNOTE.TXT Section 4.5.3: ZIP64 Extended Information Extra Field (tag 0x0001).
        let extraOffset = offset + 46 + nameLen
        var extraIdx = 0
        var zip64Seen = false
        while extraIdx < extraLen {
            guard extraLen - extraIdx >= 4 else {
                throw ArchiveFailure.invalidSource("Truncated extra field for \(pathStr)")
            }
            let tag = ZipBinaryBuffer.readUInt16(from: buffer, offset: extraOffset + extraIdx)
            let size = Int(ZipBinaryBuffer.readUInt16(from: buffer, offset: extraOffset + extraIdx + 2))
            guard size <= extraLen - extraIdx - 4 else {
                throw ArchiveFailure.invalidSource("Truncated extra field for \(pathStr)")
            }
            if tag == ZipMagic.zip64ExtraFieldTag {
                guard !zip64Seen else {
                    throw ArchiveFailure.invalidSource("Duplicate ZIP64 extra field")
                }
                zip64Seen = true
                var fieldPos = extraOffset + extraIdx + 4
                let fieldEnd = fieldPos + size
                func readSize() throws -> UInt64 {
                    guard fieldEnd - fieldPos >= 8 else {
                        throw ArchiveFailure.invalidSource("Missing ZIP64 value for \(pathStr)")
                    }
                    let value = ZipBinaryBuffer.readUInt64(from: buffer, offset: fieldPos)
                    fieldPos += 8
                    return value
                }
                if uncompSize == 0xFFFFFFFF { uncompSize = try readSize() }
                if compSize == 0xFFFFFFFF { compSize = try readSize() }
                if localOffset == 0xFFFFFFFF { localOffset = try readSize() }
                if diskStart == 0xFFFF {
                    guard fieldEnd - fieldPos >= 4 else {
                        throw ArchiveFailure.invalidSource("Missing ZIP64 disk number")
                    }
                    diskStart = ZipBinaryBuffer.readUInt32(from: buffer, offset: fieldPos)
                }
            }
            extraIdx += 4 + size
        }
        guard zip64Seen || (uncompSize != 0xFFFFFFFF && compSize != 0xFFFFFFFF && localOffset != 0xFFFFFFFF && diskStart != 0xFFFF) else {
            throw ArchiveFailure.invalidSource("Missing ZIP64 extra field for \(pathStr)")
        }
        guard diskStart == 0 else {
            throw ArchiveFailure.invalidSource("Multi-disk archives are unsupported")
        }

        let posixMode = (extAttrs >> 16) & 0xF000
        let isSymlink = posixMode == 0xA000
        let isDirectory = pathStr.hasSuffix("/") || posixMode == 0x4000 || (extAttrs & 0x10 != 0)

        let entry = ZipCentralEntry(
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
        )

        return (entry, recordTotalLen)
    }

    /// Decodes entry filename bytes using UTF-8 or CP437 fallback according to APPNOTE.TXT Appendix D.
    private static func decodeEntryPath(
        bytes: UnsafeRawBufferPointer.SubSequence,
        generalFlags: UInt16
    ) -> String {
        let isUTF8 = (generalFlags & 0x0800) != 0
        let cp437Encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(0x0411))

        if isUTF8 {
            return String(bytes: bytes, encoding: .utf8) ?? String(decoding: bytes, as: UTF8.self)
        } else if let validUTF8 = String(bytes: bytes, encoding: .utf8) {
            return validUTF8
        } else {
            return String(bytes: bytes, encoding: cp437Encoding) ?? String(decoding: bytes, as: UTF8.self)
        }
    }
}
