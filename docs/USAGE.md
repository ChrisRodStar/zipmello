# API Usage Guide

## Archive Reader

### Read a File Member
```swift
import ZipMello

let reader = try await ArchiveReader.open(archiveURL)
let data = try await reader.read("chapter/001.jpg", lookup: .exact)
await reader.close()
```

### In-Memory Archive Reading
```swift
import ZipMello

let reader = try ArchiveMemoryReader(data: archiveBytes, lookup: .compatible)
let data = try reader.read("chapter/001.jpg")
```

### Compatible Lookup
Lookup mode `.compatible` resolves case variations, normalization differences, and percent-encoded paths (e.g. `OEBPS/Cover.PNG` vs `oebps/cover.png`). Ambiguous aliases throw `ArchiveFailure.ambiguousEntry`.

---

## Archive Writer

### Create Archive from Assets
```swift
import ZipMello

let assets: [ArchiveAsset] = [
    .init(path: "001.jpg", content: .file(imageURL), compression: .deflate),
    .init(path: "metadata.json", content: .bytes(jsonData), compression: .stored),
    .init(path: "empty_dir/", content: .directory)
]

try await ArchiveWriter().create(at: destinationURL, assets: assets)
```

---

## Consumer Adapters (`ZipMelloConsumers`)

### Page Session Caching (`ArchivePageStore`)
Coalesces concurrent requests and bounds cached extracted files with explicit leases:

```swift
import ZipMelloConsumers

let pageStore = try ArchivePageStore(directory: cacheDirectory)
let session = try await pageStore.session(for: archiveURL)
let lease = try await session.lease("001.jpg")

// Access extracted image file at lease.url
await lease.release()
```

### Comic Metadata (`LocalComicArchive`)
Parses nested `ComicInfo.xml` metadata, orders comic pages naturally, and extracts cover images:

```swift
import ZipMelloConsumers

let comic = try await LocalComicArchive.open(cbzURL)
let pageCount = comic.pageCount
let coverData = try await comic.coverData()
```
