# ZipMello

Zero-dependency native ZIP & CBZ codec for Swift 6 on iOS 27 and macOS 27.

ZipMello provides high-performance, memory-efficient ZIP operations with zero third-party package dependencies. It supports reading, extracting, creating, and streaming compressed archives with hardware-accelerated CRC32 checksums, ZIP64 format support, and configurable resource budgets.

---

## Installation

Add ZipMello as a local Swift package dependency in `Package.swift`:

```swift
.product(name: "ZipMello", package: "zipmello"),
.product(name: "ZipMelloConsumers", package: "zipmello") // For comic metadata, page stores & dictionary preflight
```

---

## Quickstart

### Read an Entry
```swift
import ZipMello

let reader = try await ArchiveReader.open(archiveURL)
do {
    let data = try await reader.read("001.jpg")
    print("Read \(data.count) bytes")
    await reader.close()
} catch {
    await reader.close()
    throw error
}
```

### Create a ZIP or CBZ Archive
```swift
import ZipMello

let assets: [ArchiveAsset] = [
    .init(path: "001.jpg", content: .file(pageURL), compression: .deflate),
    .init(path: "ComicInfo.xml", content: .bytes(xmlData), compression: .stored)
]

try await ArchiveWriter().create(at: outputURL, assets: assets)
```

---

## Key Features

- **Zero Third-Party Dependencies**: Built exclusively using Darwin system APIs (`zlib`, `libz`) and Swift Standard Library.
- **Hardware-Accelerated CRC32**: Vector-accelerated checksum validation via Darwin `libz`.
- **Zero-Copy Streaming DEFLATE**: Raw RFC 1951 stream compression and decompression using system `zlib`.
- **Multi-Lane Concurrent Reads**: Independent positional reads (`pread`) across parallel reader lanes without file cursor contention.
- **ZIP64 Support**: Automatic ZIP64 EOCD Record and Locator generation for entry counts $\ge 65,535$ or offsets $\ge 4\text{GB}$.
- **Security Enforced**: Rejects path traversal (`Zip Slip`), symlink extraction exploits, and unverified checksums.

---

## Command Line Usage

```bash
swift build -c release
swift run zipmello validate /path/to/chapter.cbz
swift run zipmello extract /path/to/package.zip /path/to/destination
swift run zipmello cbz /path/to/pages /path/to/chapter.cbz
```

---

## Performance Metrics

| Operation | Latency / Speed |
| :--- | :--- |
| **Central Directory Index Load** | **126 µs** |
| **50 MB DEFLATE Decompress** | **11.8 ms** |
| **50 MB DEFLATE Creation** | **87.8 ms** |
| **65,536-Entry ZIP64 Creation** | **0.49 s** |
| **Full Release Test Suite (35 tests)** | **0.49 s** |

---

## Documentation

- [API Usage Guide](docs/USAGE.md)
- [Architecture & Engine Design](docs/ARCHITECTURE.md)
