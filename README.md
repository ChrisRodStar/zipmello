<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/banner-dark.svg">
    <source media="(prefers-color-scheme: light)" srcset="assets/banner-light.svg">
    <img alt="ZipMello Banner" src="assets/banner-dark.svg" width="100%">
  </picture>
</p>

<p align="center">
  <a href="https://github.com/ChrisRodStar/zipmello/actions/workflows/ci.yml"><img src="https://img.shields.io/github/actions/workflow/status/ChrisRodStar/zipmello/ci.yml?branch=main&label=CI&style=flat-square&color=22c55e" alt="CI Status"></a>
  <a href="https://github.com/ChrisRodStar/zipmello/releases/tag/v1.0.0"><img src="https://img.shields.io/github/v/release/ChrisRodStar/zipmello?style=flat-square&label=Release&color=F5C77E" alt="Release v1.0.0"></a>
  <img src="https://img.shields.io/badge/Swift-6.0%20Strict-F05138?style=flat-square&logo=swift&logoColor=white" alt="Swift 6.0 Strict">
  <img src="https://img.shields.io/badge/Platforms-macOS%20%7C%20iOS%20%7C%20tvOS%20%7C%20watchOS%20%7C%20visionOS-1C1B1A?style=flat-square" alt="Platforms">
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-blue.svg?style=flat-square" alt="MIT License"></a>
</p>

---

**ZipMello** is a Swift 6 ZIP/CBZ engine built around the access patterns of comic and manga readers. It uses positional archive reads for concurrent page access, natural page ordering, bounded page leasing for scroll views, and direct in-memory archive processing.

## Reader Benchmarks

Measured head-to-head on Apple Silicon comparing ZipMello 1.0.0 against [ZIPFoundation 0.9.20](https://github.com/weichsel/ZIPFoundation):

| Benchmark | ZIPFoundation 0.9.20 | ZipMello 1.0.0 | Speedup |
| :--- | ---: | ---: | ---: |
| **Random-Access Page Reads**<br><sub>80 pages directly from .cbz</sub> | 17.0 ms | **3.2 ms** | **5.31×** |
| **Concurrent Prefetching**<br><sub>32 concurrent page reads</sub> | 7.1 ms | **1.4 ms** | **4.93×** |
| **In-Memory Volume Extraction**<br><sub>50 entries, zero disk I/O</sub> | 6.3 ms | **2.0 ms** | **3.15×** |
| **Directory Extraction**<br><sub>500 files, 50 MB to disk</sub> | 83.2 ms | **40.0 ms** | **2.08×** |
| **Central Directory Inspection**<br><sub>5,000 entries</sub> | 14.2 ms | **8.0 ms** | **1.78×** |

## Key Features

- **Lock-Free Positional Reads**: Independent `pread` calls allow background tasks to prefetch future pages without locking the file handle or stalling the main thread.
- **Natural Page Sorting**: Pages sort via `localizedStandardCompare` so `page2.jpg` precedes `page10.jpg`, automatically filtering out `__MACOSX`, dot-underscore files, and `.DS_Store`.
- **Bounded Page Leasing (`ArchivePageStore`)**: Reference-counted page leasing with bounded disk usage and LRU eviction, keeping files on disk while visible in scroll views.
- **Zero-Disk Streaming**: Parse and decompress downloaded `.cbz` payloads directly from `Data` buffers without writing temporary files to flash storage.
- **Hardened `ComicInfo.xml`**: Parses and serializes ComicRack metadata with built-in XXE and expansion bomb protection.

## Quickstart

### Open Archive & Read Pages

`LocalComicArchive` loads pages in natural reading order and strips OS artifacts:

```swift
import ZipMelloConsumers

let comic = try await LocalComicArchive.open(archiveURL)

// Cover image:
if let coverData = try await comic.coverBytes() {
    // UIImage(data: coverData)
}

// Read any page by index:
let pageData = try await comic.bytes(at: 0)

// Optional ComicInfo.xml metadata:
if let info = try await comic.comicInfo() {
    print("\(info["Series"] ?? "") #\(info["Number"] ?? "")")
}

await comic.close()
```

### Bounded Page Caching for Scroll Views

Lease pages for visible cells; `ArchivePageStore` handles eviction when the lease releases:

```swift
import ZipMello

let store = try ArchivePageStore(
    directory: cacheURL,
    maximumBytes: 100 * 1024 * 1024, // 100 MB disk budget
    maximumFiles: 50
)

// In view: acquire lease
let lease = try await store.lease("page_001.jpg", from: archiveURL)
let localFileURL = lease.url

// On cell reuse / scroll offscreen:
await lease.release()
```

### Stream from Network Payloads

Read chapters directly from `Data` without touching disk:

```swift
import ZipMelloConsumers

let (data, _) = try await URLSession.shared.data(from: chapterURL)
let comic = try await LocalComicArchive.open(data: data)
let firstPage = try await comic.bytes(at: 0)
```

## Universal CLI

ZipMello also includes a universal CLI binary (`zipmello`) for inspecting, extracting, and validating archives from the terminal:

```bash
zipmello list /path/to/archive.cbz
zipmello info /path/to/archive.zip
zipmello validate /path/to/archive.zip
```

Pre-built universal binaries (`arm64` + `x86_64`) are available on the [Releases](https://github.com/ChrisRodStar/zipmello/releases) page.

## Installation

Add ZipMello to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/ChrisRodStar/zipmello.git", from: "1.0.0")
]
```

Add the core engine and reader consumers to your target:

```swift
.target(
    name: "YourApp",
    dependencies: [
        .product(name: "ZipMello", package: "zipmello"),
        .product(name: "ZipMelloConsumers", package: "zipmello")
    ]
)
```

## Documentation

- [Complete API Usage Guide](docs/USAGE.md)
- [Architecture & Engine Design](docs/ARCHITECTURE.md)

## License

ZipMello is open source software released under the [MIT License](LICENSE).

<p align="center">
  <img src="assets/branding/logo-128.png" width="48" height="48" alt="ZipMello Mascot"><br>
  <sub>Crafted with care by Melo.</sub>
</p>
