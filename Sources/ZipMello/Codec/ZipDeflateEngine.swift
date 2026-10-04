import Foundation
import zlib

/// Native streaming raw DEFLATE compression and decompression engine.
///
/// Implements RFC 1951 raw DEFLATE framing using system `libz` with `windowBits = -15`.
/// The negative windowBits parameter directs zlib to omit RFC 1950 headers/trailers and
/// RFC 1952 gzip wrappers, as required by PKWARE APPNOTE.TXT Section 4.4.5 (Compression Method 8).
enum ZipDeflateEngine {
    typealias Consumer = (_ chunk: Data) throws -> Void
    typealias Provider = (_ offset: UInt64, _ maxCount: Int) throws -> Data

    /// Decompresses a raw DEFLATE payload stream using sliding buffer windows.
    ///
    /// - Parameters:
    ///   - compressedBytes: Total count of compressed input bytes to read from `provider`.
    ///   - bufferBytes: Size in bytes of each streaming chunk buffer.
    ///   - skipCRC: If `true`, avoids computing the uncompressed CRC-32 checksum during decompression.
    ///   - provider: Async/throwing callback fetching input slices on demand.
    ///   - consumer: Throwing callback receiving decoded uncompressed chunks as they are emitted.
    /// - Returns: Computed 32-bit CRC checksum of all uncompressed output bytes.
    static func decompress(
        compressedBytes: UInt64,
        bufferBytes: Int = 65536,
        skipCRC: Bool = false,
        provider: Provider,
        consumer: Consumer
    ) throws -> UInt32 {
        var crc: UInt32 = 0
        var strm = z_stream()
        strm.zalloc = nil
        strm.zfree = nil
        strm.opaque = nil

        // Negative windowBits (-15) selects raw DEFLATE without zlib wrapper headers.
        let initResult = inflateInit2_(&strm, -15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard initResult == Z_OK else {
            throw ArchiveFailure.invalidSource("inflateInit2 failed with status \(initResult)")
        }
        defer {
            inflateEnd(&strm)
        }

        let outBuffer = UnsafeMutablePointer<Bytef>.allocate(capacity: bufferBytes)
        defer {
            outBuffer.deallocate()
        }

        var readPosition: UInt64 = 0
        var currentInputChunk: Data?
        var streamFinished = false

        while !streamFinished {
            if strm.avail_in == 0 && readPosition < compressedBytes {
                let remaining = compressedBytes - readPosition
                let fetchCount = Int(Swift.min(UInt64(bufferBytes), remaining))
                let chunk = try provider(readPosition, fetchCount)
                if chunk.isEmpty { break }
                readPosition += UInt64(chunk.count)
                currentInputChunk = chunk
            }

            guard let inputChunk = currentInputChunk, !inputChunk.isEmpty else {
                break
            }

            var flush = Z_NO_FLUSH
            if readPosition >= compressedBytes {
                flush = Z_FINISH
            }

            try inputChunk.withUnsafeBytes { rawBuf in
                guard let baseAddr = rawBuf.baseAddress else { return }
                let bytePtr = baseAddr.assumingMemoryBound(to: Bytef.self)
                let offset = inputChunk.count - Int(strm.avail_in)

                if strm.avail_in == 0 {
                    strm.next_in = UnsafeMutablePointer(mutating: bytePtr)
                    strm.avail_in = uInt(inputChunk.count)
                } else {
                    strm.next_in = UnsafeMutablePointer(mutating: bytePtr.advanced(by: offset))
                }

                strm.next_out = outBuffer
                strm.avail_out = uInt(bufferBytes)

                let res = inflate(&strm, flush)
                if res != Z_OK && res != Z_STREAM_END && res != Z_BUF_ERROR {
                    throw ArchiveFailure.invalidSource("zlib inflate error \(res)")
                }

                let produced = bufferBytes - Int(strm.avail_out)
                if produced > 0 {
                    let outputData = Data(bytes: outBuffer, count: produced)
                    try consumer(outputData)
                    if !skipCRC {
                        crc = ZipChecksum.update(current: crc, data: outputData)
                    }
                }

                if res == Z_STREAM_END {
                    streamFinished = true
                    return
                }
            }

            if streamFinished { break }

            if strm.avail_in == 0 && readPosition >= compressedBytes {
                break
            }
        }

        return crc
    }

    /// Compresses uncompressed data into a raw DEFLATE stream using sliding buffer windows.
    ///
    /// - Parameters:
    ///   - uncompressedBytes: Total count of uncompressed bytes to consume.
    ///   - bufferBytes: Size in bytes of each streaming chunk buffer.
    ///   - provider: Throwing callback providing uncompressed data chunks.
    ///   - consumer: Throwing callback receiving compressed DEFLATE bytes.
    /// - Returns: Computed 32-bit CRC checksum of all uncompressed input bytes.
    static func compress(
        uncompressedBytes: UInt64,
        bufferBytes: Int = 65536,
        provider: Provider,
        consumer: Consumer
    ) throws -> UInt32 {
        var crc: UInt32 = 0
        var strm = z_stream()
        strm.zalloc = nil
        strm.zfree = nil
        strm.opaque = nil

        let initResult = deflateInit2_(
            &strm,
            Z_DEFAULT_COMPRESSION,
            Z_DEFLATED,
            -15,
            8,
            Z_DEFAULT_STRATEGY,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard initResult == Z_OK else {
            throw ArchiveFailure.invalidSource("deflateInit2 failed with status \(initResult)")
        }
        defer {
            deflateEnd(&strm)
        }

        let outBuffer = UnsafeMutablePointer<Bytef>.allocate(capacity: bufferBytes)
        defer {
            outBuffer.deallocate()
        }

        var readPosition: UInt64 = 0
        var currentInputChunk: Data?
        var streamFinished = false

        while !streamFinished {
            if strm.avail_in == 0 && readPosition < uncompressedBytes {
                let remaining = uncompressedBytes - readPosition
                let fetchCount = Int(Swift.min(UInt64(bufferBytes), remaining))
                let chunk = try provider(readPosition, fetchCount)
                if chunk.isEmpty { break }
                readPosition += UInt64(chunk.count)
                crc = ZipChecksum.update(current: crc, data: chunk)
                currentInputChunk = chunk
                strm.avail_in = uInt(chunk.count)
            }

            var flush = Z_NO_FLUSH
            if readPosition >= uncompressedBytes {
                flush = Z_FINISH
            }

            if let inputChunk = currentInputChunk, !inputChunk.isEmpty {
                try inputChunk.withUnsafeBytes { rawBuf in
                    guard let baseAddr = rawBuf.baseAddress else { return }
                    let bytePtr = baseAddr.assumingMemoryBound(to: Bytef.self)
                    let offset = inputChunk.count - Int(strm.avail_in)
                    strm.next_in = UnsafeMutablePointer(mutating: bytePtr.advanced(by: offset))

                    strm.next_out = outBuffer
                    strm.avail_out = uInt(bufferBytes)

                    let res = deflate(&strm, flush)
                    if res != Z_OK && res != Z_STREAM_END && res != Z_BUF_ERROR {
                        throw ArchiveFailure.invalidSource("zlib deflate error \(res)")
                    }

                    let produced = bufferBytes - Int(strm.avail_out)
                    if produced > 0 {
                        let outputData = Data(bytes: outBuffer, count: produced)
                        try consumer(outputData)
                    }

                    if res == Z_STREAM_END {
                        streamFinished = true
                        return
                    }
                }
                if streamFinished { break }
            } else {
                strm.next_out = outBuffer
                strm.avail_out = uInt(bufferBytes)

                let res = deflate(&strm, Z_FINISH)
                if res != Z_OK && res != Z_STREAM_END && res != Z_BUF_ERROR {
                    throw ArchiveFailure.invalidSource("zlib deflate error \(res)")
                }

                let produced = bufferBytes - Int(strm.avail_out)
                if produced > 0 {
                    let outputData = Data(bytes: outBuffer, count: produced)
                    try consumer(outputData)
                }

                if res == Z_STREAM_END {
                    break
                }
            }

            if strm.avail_in == 0 && readPosition >= uncompressedBytes && strm.avail_out != 0 {
                break
            }
        }

        return crc
    }
}
