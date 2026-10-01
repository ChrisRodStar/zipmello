# Architecture & Engine Design

ZipMello is engineered for high performance, memory efficiency, and thread safety on Apple platforms.

---

## Subsystem Overview

```
+------------------------------------------------------------------+
|                          Public APIs                             |
|  ArchiveReader  |  ArchiveWriter  |  ArchivePageStore  |  CLI   |
+------------------------------------------------------------------+
                                  |
                                  v
+------------------------------------------------------------------+
|                    Native Codec Subsystem                        |
|                                                                  |
|  +------------------------+      +----------------------------+  |
|  | ZipCentralDirectory    |      | ZipDeflateEngine           |  |
|  | Parser (Tail Scanner)  |      | (Streaming zlib)           |  |
|  +------------------------+      +----------------------------+  |
|  | ZipChecksum            |      | ZipBinaryWriter            |  |
|  | (Darwin libz CRC32)    |      | (ZIP & ZIP64 Binary)       |  |
|  +------------------------+      +----------------------------+  |
+------------------------------------------------------------------+
                                  |
                                  v
+------------------------------------------------------------------+
|                    System Infrastructure                         |
|  Swift System FileDescriptor  |  Darwin libz  |  Dispatch Queues |
+------------------------------------------------------------------+
```

---

## Component Architecture

1. **`ZipCentralDirectoryParser`**
   - Scans the End of Central Directory (EOCD) from the tail of the file (up to 66 KiB from EOF).
   - Parses ZIP64 EOCD Record (`0x06064b50`) and Locator (`0x07064b50`) when entry counts $\ge 65,535$ or offsets $\ge 4\text{GB}$.
   - Decodes UTF-8 (`0x0800` bit 11) and CP437 legacy filename encodings.

2. **`ZipDeflateEngine`**
   - High-throughput streaming raw DEFLATE (RFC 1951) compressor and decompressor using system `zlib` (`inflateInit2_` & `deflateInit2_` with `windowBits = -15`).
   - Uses zero-copy reusable scratch buffers (`UnsafeMutableRawBufferPointer`) to eliminate Swift `Data` reallocations per chunk.

3. **`ZipChecksum`**
   - Hardware-accelerated 32-bit CRC checksum engine calling Darwin `libz` (`crc32`).
   - Validates payload integrity during streaming decompression and extraction.

4. **`ZipBinaryWriter`**
   - Streaming binary encoder writing Local Headers (`0x04034b50`), Stored/DEFLATE entry payloads, Central Directory records (`0x02014b50`), EOCD footers, and ZIP64 structures.

---

## Concurrency & Memory Safety

- **Swift Concurrency Actors**: High-level types (`ArchiveReader`, `ArchiveWriter`, `ArchiveMemoryService`) are actors backed by dedicated `DispatchSerialQueue` executors (`UnownedSerialExecutor`).
- **Positional `pread` I/O**: Multi-lane reader instances perform non-blocking positional reads (`FileDescriptor.read(fromAbsoluteOffset:into:)`) from a single shared file descriptor without seek cursor locks.
- **Atomic Staging**: Extraction and creation operations write payload chunks to isolated hidden staging files (`.extract-...` or `.archive-...`) and atomically replace the destination path only after CRC and size validation succeed.
- **Resource Limits (`ArchiveLimits`)**:
  - Maximum Archive Size (default: 512 MB)
  - Maximum Entry Size (default: 250 MB)
  - Maximum Expanded Size (default: 2 GB)
  - Maximum Entry Count (default: 20,000)
