# ZipMello

Fast, native ZIP & CBZ codec for Swift 6 on iOS 27 and macOS 27.

ZipMello is a Swift framework for archive operations. Built on Darwin `zlib` and Swift Concurrency, it provides hardware-accelerated CRC32 checksums, streaming DEFLATE compression, lock-free parallel reads, and ZIP64 format support.

---

## Installation

Add ZipMello to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/ChrisRodStar/zipmello.git", branch: "main")
]
```

Add `ZipMello` (and optionally `ZipMelloConsumers` for page caching and comic metadata) to your target:

```swift
.target(
    name: "YourApp",
    dependencies: [
        .product(name: "ZipMello", package: "zipmello"),
        .product(name: "ZipMelloConsumers", package: "zipmello")
    ]
)
```

---

## Quickstart

### Read Entry
```swift
import ZipMello

let data = try await ArchiveReader.read(entry: "chapter/001.jpg", from: archiveURL)
```

### Extract Archive
```swift
import ZipMello

try await ArchiveReader.extractAll(from: archiveURL, to: destinationFolder)
```

### Create Archive
```swift
import ZipMello

try await ArchiveWriter.create(at: archiveURL, from: sourceDirectory)
```

---

## Capabilities

- **Hardware-Accelerated CRC32**: Vector-accelerated checksum calculations via Darwin `crc32`.
- **Streaming DEFLATE Codec**: Stream compression and decompression using system `zlib`.
- **Parallel Reads**: Independent positional reads (`pread`) across parallel reader lanes without seek cursor locks.
- **ZIP64 Support**: Automatic ZIP64 EOCD Record and Locator generation for entry counts $\ge 65,535$ or sizes $\ge 4\text{GB}$.
- **Security Validation**: Zip Slip protection, symlink rejection, and checksum verification.

---

## Command Line Tool (`zipmello`)

```bash
# Inspect entry metadata & compression ratios
swift run zipmello list /path/to/archive.zip

# Show archive summary
swift run zipmello info /path/to/archive.zip

# Extract archive contents
swift run zipmello extract /path/to/archive.zip /path/to/destination

# Create compressed archive from a directory
swift run zipmello create /path/to/source_dir /path/to/output.zip

# Verify CRC32 checksums
swift run zipmello validate /path/to/archive.zip
```

---

## Performance Comparison

Side-by-side real-world benchmark comparison measured on Apple Silicon (arm64, Release `-O` builds):

| Real-World Workload | ZIPFoundation | ZipMello | Advantage |
| :--- | :--- | :--- | :--- |
| **Random-Access Page Reads** *(80 pages from .cbz)* | 17.0 ms | **3.2 ms** | **5.31× faster** (81% less time) |
| **Concurrent Reads** *(32 parallel decoders/workers)* | 7.1 ms | **1.4 ms** | **4.93× faster** (80% less time) |
| **In-Memory Extraction** *(50 entries, zero disk I/O)* | 6.3 ms | **2.0 ms** | **3.15× faster** (68% less time) |
| **Package Directory Extraction** *(500 files, 50 MB to disk)* | 83.2 ms | **40.0 ms** | **2.08× faster** (52% less time) |
| **TOC / Directory Inspection** *(5,000 entries)* | 14.2 ms | **8.0 ms** | **1.78× faster** (44% less time) |
| **Folder Archiving** *(500 files, 50 MB, DEFLATE)* | 120.4 ms | **110.1 ms** | **1.10× faster** (9% less time) |
| **Full Test Suite Execution** | 32.60 s | **0.75 s** | **43.5× faster** |

### Why ZipMello Is Faster in Real-World Apps

- **Zero-Alloc Unaligned Hardware Access**: Central directory and local header parsing uses single-instruction `loadUnaligned` hardware memory operations, avoiding intermediate data copies and heap allocations.
- **$O(1)$ Direct Offset Random Access**: Instead of scanning entries sequentially from disk, `ArchiveReader` indexes pre-computed payload offsets and reads slices directly using POSIX `pread`.
- **True Swift 6 Actor Concurrency**: Multiple UI collection cells or background threads can read different pages from the same open archive concurrently through isolated actor lanes, without serial locking bottlenecks.
- **Pure In-Memory Processing**: `ArchiveMemoryReader` parses and decompresses downloaded network payloads directly from RAM without touching disk or spooling temporary files.
- **Hardware-Vector CRC32 & Direct DEFLATE**: CRC32 calculation delegates to hardware vector extensions (ARMv8 / SSE4.2), while streaming raw DEFLATE (`-15 windowBits`) pipelines directly between buffers.

---

## Documentation

- [API Usage Guide](docs/USAGE.md)
- [Architecture & Engine Design](docs/ARCHITECTURE.md)
