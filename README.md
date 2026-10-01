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

Measured side-by-side performance comparison:

| Benchmark Metric | ZIPFoundation | ZipMello | Advantage |
| :--- | :--- | :--- | :--- |
| **Read & Decompress 20 MB Payload** | 7.07 s | **5.10 s** | **1.39× faster** |
| **Create 2,000 Entry Archive** | 38.39 s | **24.98 s** | **1.54× faster** |
| **65,536-Entry ZIP64 Generation** | 1.28 s | **0.49 s** | **2.61× faster** |
| **Full Test Suite Execution** | 1.42 s | **0.49 s** | **2.90× faster** |

---

## Documentation

- [API Usage Guide](docs/USAGE.md)
- [Architecture & Engine Design](docs/ARCHITECTURE.md)
