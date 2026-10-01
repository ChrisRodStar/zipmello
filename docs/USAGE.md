# API usage

## Read and install

```swift
import ZipMello

let reader = try await ArchiveReader.open(chapterURL)
let members = try await reader.listing()
let bytes = try await reader.read("001.jpg", lookup: .compatible)
try await reader.extractAll(to: newStagingDirectory)
await reader.close()

// One executor hop per downloaded response, no temporary ZIP.
let page = try await ArchiveMemoryService.shared.read(
    "chapter.md", data: responseData, limits: .sourcePages
)

// For batch access on your own bounded worker, index immutable bytes once.
let memory = try ArchiveMemoryReader(data: responseData)
let firstPage = try memory.read("001.jpg")
```

Exact lookup is the default on file readers. `.compatible` prefers an exact match, then handles leading `./`, case/Unicode normalization, and safe percent-decoded aliases. Ambiguous fallback names throw. Extraction uses validated raw names with harmless leading `./` removed, never lookup aliases. Tree extraction rejects file/directory conflicts and case/Unicode destination collisions before creating staging.

`consume(_:consumer:)` streams expanded chunks; `validate(progress:)` checks every file without retaining expanded data. Chunks are unverified until the operation successfully returns, so stream consumers must stage side effects. `read` returns a whole member; use streaming or file extraction for large data.

## Export and progress

```swift
try await ArchiveWriter().create(
    at: exportURL, directory: chapterDirectory,
    compression: .stored, progress: progressHandler
)
```

Directory export strips the parent, naturally orders children, includes nested/empty directories, and retains hidden metadata by default. The CLI opts to skip hidden files. Explicit ordered `.bytes`, `.file`, and `.directory` assets remain available, with stored/Deflate selection per file. Progress callbacks run synchronously on workers; UI callers should throttle updates and hop to their UI actor.

Destinations need an existing parent and must not exist. Single-file extraction and ZIP creation synchronize before publication by default. Disposable page-cache files use `.buffered` extraction. Whole-tree extraction closes all files before publishing but does not fsync every file or claim crash-durable directory commits. Consumers validate source/model contents before replacing an installed generation.

## Reader file ownership

```swift
let pages = try ArchivePageStore(directory: cacheRoot)
let chapter = try await pages.session(for: chapterURL)
let lease = try await chapter.lease("001.jpg")
// Keep lease alive for all consumers that need its URL.
await lease.release()
await pages.removeAll()
```

The store coalesces concurrent requests and bounds cached files, active leases, in-flight bytes, and extractions. Clearing retires active files; they remain readable until release. Explicit release avoids deferred cleanup tasks. A chapter session represents an immutable archive generation and avoids repeated fingerprint checks on cache hits; reopen it when replacing the archive. The URL-based `lease(_:from:)` convenience fingerprints each acquisition. Melloku still owns shared chapter references and source-archive deletion policy.

## Consumer adapters and limits

`LocalComicArchive` provides lazy image/text pages, natural order, hidden/description filtering, nested ComicInfo lookup, first-image cover bytes, and one-based `N.desc.txt` mapping. `ComicInfoCodec` round-trips flat metadata and page attributes, including fractional numbers and identity notes. It accepts UTF-8 and BOM-marked UTF-16, rejects DTD/entity declarations, and limits metadata to 4 MiB. Image decoding and chapter database changes remain in Melloku.

`ArchivePackageInstaller` extracts a staged nested source/model tree. `DictionaryArchivePreflight` checks every member's CRC and expansion budgets, then validates an index title when present before native conversion. It does not replace Hoshi dictionary conversion, CoreML compilation, or their app installation transactions.

Default budgets remain 512 MiB physical ZIP, 250 MiB per member, 2 GiB declared expansion, and 20,000 entries. `.sourcePages` preserves Melloku's decimal 64,000,000-byte input and 32,000,000-byte member caps; `.sourcePackages` caps input/expansion at 64,000,000 bytes. Opt-in `.models` and `.dictionaries` profiles allow larger installations with finite budgets. All profiles are configurable; representative fixture sizes, available disk, and app policy determine the final installation allowance.

Apple streaming remains the default. Four read lanes and bounded libdeflate are explicit workload choices. The bulk writer supports ZIP64 directory counts/offsets and rejects individual members at the 32-bit size boundary. ZIP64 local descriptors and zero-size/zero-offset central fields have independent interoperability fixtures; multi-gigabyte member writing is outside the audited app requirements. RAR/CBR, password encryption, archive mutation, and EPUB interpretation are not supplied.

