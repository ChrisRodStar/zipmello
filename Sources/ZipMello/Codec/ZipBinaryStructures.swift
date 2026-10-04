import Foundation

/// Magics and binary structure constants for PKZIP and ZIP64 standards.
enum ZipMagic {
    static let localHeader: UInt32 = 0x04034b50            // PK\x03\x04
    static let centralDirectoryHeader: UInt32 = 0x02014b50 // PK\x01\x02
    static let endOfCentralDirectory: UInt32 = 0x06054b50   // PK\x05\x06
    static let zip64EOCDRecord: UInt32 = 0x06064b50        // PK\x06\x06
    static let zip64EOCDLocator: UInt32 = 0x07064b50       // PK\x07\x06
    static let dataDescriptor: UInt32 = 0x08074b50         // PK\x07\x08
    static let zip64ExtraFieldTag: UInt16 = 0x0001
}

/// Parsed End of Central Directory (EOCD) information.
struct ZipEOCD: Sendable {
    let diskNumber: UInt32
    let startDisk: UInt32
    let diskEntries: UInt64
    let totalEntries: UInt64
    let centralDirectorySize: UInt64
    let centralDirectoryOffset: UInt64
    let commentLength: UInt16
}

/// Parsed Central Directory entry record.
struct ZipCentralEntry: Sendable {
    let versionMadeBy: UInt16
    let versionNeeded: UInt16
    let generalPurposeFlags: UInt16
    let compressionMethod: UInt16
    let lastModTime: UInt16
    let lastModDate: UInt16
    let crc32: UInt32
    let compressedSize: UInt64
    let uncompressedSize: UInt64
    let filenameLength: UInt16
    let extraFieldLength: UInt16
    let commentLength: UInt16
    let diskNumberStart: UInt32
    let internalAttributes: UInt16
    let externalAttributes: UInt32
    let localHeaderOffset: UInt64
    let path: String
    let isDirectory: Bool
    let isSymlink: Bool
}

/// Low-level little-endian binary stream and buffer operations.
enum ZipBinaryBuffer {
    @inline(__always)
    static func readUInt16(from buffer: UnsafeRawBufferPointer, offset: Int) -> UInt16 {
        guard offset + 2 <= buffer.count else { return 0 }
        return UInt16(littleEndian: buffer.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
    }

    @inline(__always)
    static func readUInt32(from buffer: UnsafeRawBufferPointer, offset: Int) -> UInt32 {
        guard offset + 4 <= buffer.count else { return 0 }
        return UInt32(littleEndian: buffer.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
    }

    @inline(__always)
    static func readUInt64(from buffer: UnsafeRawBufferPointer, offset: Int) -> UInt64 {
        guard offset + 8 <= buffer.count else { return 0 }
        return UInt64(littleEndian: buffer.loadUnaligned(fromByteOffset: offset, as: UInt64.self))
    }

    @inline(__always)
    static func writeUInt16(_ value: UInt16, into buffer: UnsafeMutableRawBufferPointer, offset: Int) {
        guard offset + 2 <= buffer.count else { return }
        buffer.storeBytes(of: value.littleEndian, toByteOffset: offset, as: UInt16.self)
    }

    @inline(__always)
    static func writeUInt32(_ value: UInt32, into buffer: UnsafeMutableRawBufferPointer, offset: Int) {
        guard offset + 4 <= buffer.count else { return }
        buffer.storeBytes(of: value.littleEndian, toByteOffset: offset, as: UInt32.self)
    }

    @inline(__always)
    static func writeUInt64(_ value: UInt64, into buffer: UnsafeMutableRawBufferPointer, offset: Int) {
        guard offset + 8 <= buffer.count else { return }
        buffer.storeBytes(of: value.littleEndian, toByteOffset: offset, as: UInt64.self)
    }
}
