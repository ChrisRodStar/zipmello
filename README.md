# ZipMello

ZIP operations for Swift on iOS 27 and macOS 27.

Read ZIP members from files or memory, extract archives, create ZIP and CBZ files, and validate CRC checksums. ZipMello includes configurable size limits, progress reporting, and a bounded page cache for comic readers.

## Use the package

Requires Swift 6.4. Add this checkout as a local Swift package dependency and select `ZipMello`. Select `ZipMelloConsumers` for comic metadata, local-comic access, package extraction, and dictionary preflight.

```swift
import ZipMello

let reader = try await ArchiveReader.open(chapterURL)
do {
    let page = try await reader.read("001.jpg")
    print("Read \(page.count) bytes")
    await reader.close()
} catch {
    await reader.close()
    throw error
}
```

Readers index entries once. Reads verify CRC and expanded size. Extraction and creation use staging and publish completed output without overwriting an existing destination.

## Command line

```sh
swift build
swift test -c release
swift run zipmello validate /path/to/chapter.cbz
swift run zipmello extract /path/to/package.zip /path/to/new-directory
swift run zipmello cbz /path/to/pages /path/to/new-chapter.cbz
```

## Supported operations

- Indexed file and memory reads, streaming consumption, and compatible member lookup.
- Single-member and whole-tree extraction with path, size, and collision checks.
- Ordered ZIP/CBZ creation and recursive directory export.
- Reader sessions and bounded extracted-file caching with explicit leases.
- Local-comic page ordering, text and descriptions, ComicInfo XML, and dictionary CRC/title preflight.

Default limits are 512 MiB per archive, 250 MiB per member, 2 GiB declared expansion, and 20,000 entries. Source, model, and dictionary profiles provide configurable alternatives.

Creation rejects individual members of 4 GiB or larger. RAR/CBR, encrypted ZIPs, and archive mutation are unsupported. Whole-tree extraction does not promise crash-durable directory commits. ZIPFoundation remains the modified internal engine; its [MIT license](Vendor/ZIPFoundation/LICENSE) and the [libdeflate license](Vendor/ZIPFoundation/LIBDEFLATE-LICENSE) are included.

## Performance

The measured 4,000-entry extraction took 339.1 ms versus 535.5 ms for upstream ZIPFoundation. A 128-page CBZ export took 24.0 ms versus 32.8 ms. Some independent small reads and page-cache requests were slower. These are host library measurements, not an app-wide speedup. See [full results and methodology](Benchmarks/REPLACEMENT.md).

[API usage](docs/USAGE.md) · [Architecture](docs/ARCHITECTURE.md) · [Melloku integration](docs/MELLOKU.md) · [Benchmarks](Benchmarks/README.md)
