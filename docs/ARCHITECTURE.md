# Architecture & Subsystem Design

ZipMello is designed for thread safety, low memory overhead, and high performance on Apple platforms (iOS 27 / macOS 27). It relies on zero third-party dependencies.

---

## Codec Subsystem (`Sources/ZipMello/Codec/`)

The core binary parsing and streaming engines are contained in `Sources/ZipMello/Codec/`:

1. **`ZipBinaryStructures`**: High-performance little-endian binary buffer reader and writer. Defines ZIP and ZIP64 magic signatures (`0x04034b50`, `0x02014b50`, `0x06054b50`, `0x06064b50`, `0x07064b50`).
2. **`ZipChecksum`**: Hardware-accelerated 32-bit CRC checksum calculation leveraging Darwin `libz` (`crc32`).
3. **`ZipDeflateEngine`**: Streaming raw RFC 1951 DEFLATE compressor and decompressor built directly on system `zlib` (`inflateInit2_` & `deflateInit2_` with `windowBits = -15`).
4. **`ZipCentralDirectoryParser`**: Tail-scanning ZIP/ZIP64 EOCD and central directory parser. Decodes UTF-8 (`0x0800` bit 11) and legacy CP437 filenames.
5. **`ZipBinaryWriter`**: Streaming binary creator writing local headers, Stored/DEFLATE payloads, central directory records, and automatic ZIP64 footers.

---

## Concurrency & Actor Model

- **Actor Isolation**: High-level types (`ArchiveReader`, `ArchiveWriter`, `ArchiveMemoryService`) are Swift actors that run on dedicated `DispatchSerialQueue` executors (`UnownedSerialExecutor`).
- **Positional File Reads**: Positional file reads use Swift System `FileDescriptor.read(fromAbsoluteOffset:into:)` (`pread`). Multiple reader lanes perform concurrent reads from a single shared file descriptor without seek cursor contention or global locks.
- **Atomic Staging**: Extraction and archive creation write to temporary staging files (`.extract-...` or `.archive-...`) and atomically rename them to the destination path only after CRC and budget validation succeed.

---

## Resource & Security Limits

`ArchiveLimits` enforces memory and security bounds across all operations:

- **Zip Slip Prevention**: Rejects relative path traversal components (`..`, `.`, leading `/`, `\`, `:`) in `ArchivePath.validate`.
- **Symlink Protection**: Rejects symlink entry extraction (`POSIX` mode `0xA000`) to prevent filesystem symlink exploits.
- **Budget Enforcements**:
  - Maximum archive byte size (default: 512 MB)
  - Maximum single entry size (default: 250 MB)
  - Maximum expanded archive size (default: 2 GB)
  - Maximum entries per directory (default: 20,000)
