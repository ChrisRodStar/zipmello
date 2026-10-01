import Foundation
import CLibdeflate

/// Optional, bounded raw-DEFLATE experiment. Streaming remains the default.
public enum WholeBufferDeflate {
    public static func compress(_ input: Data) throws -> Data {
        guard let compressor = libdeflate_alloc_compressor(6) else { throw Archive.ArchiveError.unwritableArchive }
        defer { libdeflate_free_compressor(compressor) }
        var output = Data(count: libdeflate_deflate_compress_bound(compressor, input.count))
        let count = input.withUnsafeBytes { source in
            output.withUnsafeMutableBytes { target in
                libdeflate_deflate_compress(compressor, source.baseAddress, source.count, target.baseAddress, target.count)
            }
        }
        guard count > 0 else { throw Archive.ArchiveError.unwritableArchive }
        output.count = count
        return output
    }

    public static func decompress(_ input: Data, expandedBytes: Int) throws -> Data {
        guard expandedBytes >= 0, let decompressor = libdeflate_alloc_decompressor() else {
            throw Archive.ArchiveError.unreadableArchive
        }
        defer { libdeflate_free_decompressor(decompressor) }
        var output = Data(count: max(1, expandedBytes))
        var actual = 0
        var consumed = 0
        let status = input.withUnsafeBytes { source in
            output.withUnsafeMutableBytes { target in
                libdeflate_deflate_decompress_ex(decompressor, source.baseAddress, source.count,
                    target.baseAddress, expandedBytes, &consumed, &actual)
            }
        }
        guard status == LIBDEFLATE_SUCCESS, actual == expandedBytes, consumed == input.count else {
            throw Archive.ArchiveError.unreadableArchive
        }
        output.count = actual
        return output
    }
}
