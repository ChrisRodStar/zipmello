import Foundation
import zlib

/// Hardware-accelerated 32-bit CRC checksum calculation engine.
enum ZipChecksum {
    /// Computes or updates a running 32-bit CRC checksum over an unsafe raw buffer pointer.
    @inline(__always)
    static func update(current: UInt32 = 0, buffer: UnsafeRawBufferPointer) -> UInt32 {
        guard let baseAddress = buffer.baseAddress, buffer.count > 0 else { return current }
        let pointer = baseAddress.assumingMemoryBound(to: Bytef.self)
        return UInt32(zlib.crc32(uLong(current), pointer, uInt(buffer.count)))
    }

    /// Computes or updates a running 32-bit CRC checksum over a `Data` buffer.
    @inline(__always)
    static func update(current: UInt32 = 0, data: Data) -> UInt32 {
        if data.isEmpty { return current }
        return data.withUnsafeBytes { buffer in
            update(current: current, buffer: buffer)
        }
    }
}
