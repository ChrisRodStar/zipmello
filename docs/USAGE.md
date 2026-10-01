# API Usage Guide

ZipMello provides both high-level convenience extensions and structured actor APIs for archive reading, extraction, streaming, and creation.

---

## 1. Archive Reading

### Single-Line Reading
Read entry data in one call:

```swift
import ZipMello

let data = try await ArchiveReader.read(entry: "chapter/001.jpg", from: archiveURL)
```

### Actor-Based Reading
Open an archive for repeated entry reads:

```swift
import ZipMello

let reader = try await ArchiveReader.open(archiveURL)
let members = try await reader.listing()

for member in members {
    let data = try await reader.read(member.path)
    print("Read \(member.path) (\(data.count) bytes)")
}

await reader.close()
```

### In-Memory Archive Reading
Read directly from `Data` buffers without writing to disk:

```swift
import ZipMello

let reader = try ArchiveMemoryReader(data: zipData, lookup: .compatible)
let data = try reader.read("chapter/001.jpg")
```

### Compatible Path Lookup
Lookup mode `.compatible` handles case variations, unicode normalization, leading `./`, and percent-encoded filenames:

```swift
// Matches "OEBPS/Cover.PNG", "oebps/cover.png", or "./OEBPS/cover.png"
let data = try await reader.read("oebps/cover.png", lookup: .compatible)
```

---

## 2. Extraction & Creation

### Single-Line Extraction
```swift
import ZipMello

// Extract all entries into a folder
try await ArchiveReader.extractAll(from: archiveURL, to: destinationFolder)

// Extract a single file
try await ArchiveReader.extract(entry: "chapter/001.jpg", from: archiveURL, to: destinationFile)
```

### Single-Line Archive Creation
```swift
import ZipMello

// Compress a directory into a ZIP archive
try await ArchiveWriter.create(at: outputZipURL, from: inputDirectoryURL, compression: .deflate)
```

### Structured Asset Creation
Build custom archives with mixed memory, file, and directory assets:

```swift
import ZipMello

let assets: [ArchiveAsset] = [
    .init(path: "001.jpg", content: .file(pageURL), compression: .deflate),
    .init(path: "metadata.json", content: .bytes(jsonData), compression: .stored),
    .init(path: "subfolder/", content: .directory)
]

try await ArchiveWriter.create(at: outputZipURL, assets: assets)
```

---

## 3. High-Level Consumers (`ZipMelloConsumers`)

### Page Session Cache (`ArchivePageStore`)
Coalesces concurrent requests and bounds extracted files with explicit leases:

```swift
import ZipMelloConsumers

let store = try ArchivePageStore(directory: cacheDirectory)
let session = try await store.session(for: archiveURL)
let lease = try await session.lease("001.jpg")

// Use extracted file at lease.url
print("Extracted page at: \(lease.url.path)")

await lease.release()
```

### Comic Archives & Metadata (`LocalComicArchive`)
Parse comic book archives (CBZ), natural page order, and `ComicInfo.xml` metadata:

```swift
import ZipMelloConsumers

let comic = try await LocalComicArchive.open(cbzURL)
print("Page count: \(comic.pageCount)")

if let coverData = try await comic.coverData() {
    print("Cover size: \(coverData.count) bytes")
}
```
