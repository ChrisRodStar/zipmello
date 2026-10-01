import Foundation
import zlib

/// Hardware-accelerated 32-bit CRC checksum calculation engine.
///
/// Delegates to Apple's system `libz`, which utilizes hardware-accelerated CRC-32 vector instructions
/// (ARMv8 CRC32 extensions on Apple Silicon and SSE4.2/PCLMULQDQ on Intel) for gigabyte-per-second throughput.
enum ZipChecksum {
    /// Computes or updates a running 32-bit CRC-32 checksum over an unsafe raw buffer pointer.
    ///
    /// - Parameters:
    ///   - current: Running CRC-32 value from preceding chunks, or `0` for the initial block.
    ///   - buffer: Raw byte buffer over which the checksum is computed.
    /// - Returns: Updated 32-bit CRC checksum.
    @inline(__always)
    static func update(current: UInt32 = 0, buffer: UnsafeRawBufferPointer) -> UInt32 {
        guard let baseAddress = buffer.baseAddress, buffer.count > 0 else {
            return current
        }
        let pointer = baseAddress.assumingMemoryBound(to: Bytef.self)
        return UInt32(zlib.crc32(uLong(current), pointer, uInt(buffer.count)))
    }

    /// Computes or updates a running 32-bit CRC-32 checksum over a `Data` buffer.
    ///
    /// - Parameters:
    ///   - current: Running CRC-32 value from preceding chunks, or `0` for the initial block.
    ///   - data: Data buffer over which the checksum is computed.
    /// - Returns: Updated 32-bit CRC checksum.
    @inline(__always)
    static func update(current: UInt32 = 0, data: Data) -> UInt32 {
        if data.isEmpty {
            return current
        }
        return data.withUnsafeBytes { buffer in
            update(current: current, buffer: buffer)
        }
    }
}
