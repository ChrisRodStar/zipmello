# Archive ownership and consumer boundaries

`ArchiveReader` builds a validated path index once and stores immutable, Sendable descriptors: offsets, sizes, compression method, and CRC. ZIPFoundation's mutable archive cursor is released after parsing. A single read-only Swift System file descriptor supplies positional reads. Its immutable owner closes it when the last reader/operation releases it. File identity and timestamps are checked against the path and descriptor around parsing. Archives must remain immutable for the remainder of a session.

A dedicated `DispatchSerialQueue` supplies each actor's serial executor. Default reads execute on the reader's queue; optional two/four-lane readers use dedicated queue-backed actors sharing the same positional descriptor and index. They never share a seek cursor, duplicate the index, or block Swift's cooperative executor. In-memory output reserves its validated size; input chunks adopt allocated storage without an extra initialization/copy. Reads return encoded bytes, not decoded images.

`ArchiveSessionPool` coalesces same-path opens, fingerprints device/inode/size/modification/change times, evicts by recency, and caps cached sessions and estimated index weight. Distinct in-flight opens are also bounded; saturation returns `sessionCapacityExceeded` so a caller can back off. The index accounting is a conservative model, not a hard allocator/RSS cap. Eviction or pool clearing releases ownership rather than forcibly closing a reader used by another operation. In-flight operations retain the file descriptor. These are descriptor leases, not Melloku's application-level chapter references or extracted-file leases.

Opening validates paths, duplicate names, entry count, physical archive size, per-entry expanded size, total declared expansion, supported compression, encryption rejection, and payload ranges. Parsed directory count must equal the declared count. Symlinks are rejected. Extraction checks actual emitted bytes, exact expanded length, and CRC. Indexing is not an extracted-data cache.

`ArchiveWriter` validates ordered assets, opens file inputs with no-follow semantics, confirms size/type on the descriptor, reads sequentially, and rejects source size/timestamp changes observed after writing. `BulkArchiveWriter` writes local records/data, patches their headers, then writes the central directory once. It supports ZIP64 directory counts/offsets; entries of 4 GiB or larger are deliberately unsupported by this creation path. Default Melloku entry limits are 250 MiB. Standard stored and raw-DEFLATE records remain interoperable with ZIPFoundation and system unzip.

A unique sibling staging file is moved into place only after completion, checksums, budgets, and synchronization. Existing destinations are never replaced. Output payload budgets are checked per emitted chunk and directory sizes during finalization. Small headers/records can transiently exceed the cap before a failure removes staging. This is not a crash-durable directory transaction. No part of a failed archive is published.

Apple streaming compression remains the default. An explicitly selected libdeflate path is limited to both compressed and expanded inputs within at most 4 MiB; larger reads/writes fall back to streaming. Compressors/decompressors are owned by each operation. This experiment trades additional bounded memory and a C dependency for workload-dependent speed; it is not a universal replacement.

Default reader buffers remain 64 KiB and read concurrency remains one. Export defaults are 256 KiB based on the release sweep. `ArchiveTuning.pagePrefetch` selects four lanes; `smallEntries` opts into bounded libdeflate. Callers should bound outstanding requests and retained output bytes, independently of the lane count. Use streaming file extraction for large members. A pool never shares extracted page bytes or stores application metadata.

## Melloku consumers

| Stage | Required contract | Ownership outside this library |
| --- | --- | --- |
| 03 | Inspect/extract source ZIP Payload and prepare staged installation | Manifest/Wasm validation and repository commit |
| 04 | Local CBZ/ZIP listing, natural page order, lazy entries, metadata and descriptions | ComicInfo parsing, file scopes, library identity and shared chapter references |
| 06 | Stream pages/ComicInfo into CBZ, import existing downloads, support failed/cancelled writes | Download queue, retries, manifests, promotion and storage accounting |
| 07–08 | Reuse archive sessions, memoize extracted entries, return leased files, unpack model ZIPs | Reader prefetch, image processing, model validation/compilation and cache policy |
| 09 | Validate dictionary ZIPs under budgets before native import | Dictionary format conversion, native handles and installation generations |

Stage 11's JSON/binary-plist backup requirements add no ZIP consumer. Stage 04 explicitly supports CBZ/ZIP; summary mentions of CBR do not establish RAR support. Melloku's specifications remain the source of truth in `/Users/chris/Desktop/Workspace/Products/Melloku/docs/parity`. This package supplies archive mechanisms, not complete implementations of every stage.

## Replacement APIs added October 1, 2026

The immutable `ValidatedArchiveIndex` is shared by file and memory readers. `ArchiveMemoryReader` supports synchronous batches on bounded workers; `ArchiveMemoryService` reuses one executor and indexes/reads in one hop for remote responses. `ArchiveReader.open(data:)` remains available for callers needing its asynchronous session APIs. Compatible aliases are built lazily for file readers, and memory fallback scans only when an exact path is absent.

`ArchiveTreePlan` resolves harmless leading dot prefixes, all explicit/implicit directories, and conservative case/Unicode destination conflicts before extraction. A single worker streams a new private tree using Swift System `FileDescriptor.writeAll`; per-file fsync is avoided for tree extraction, which does not promise crash-durable installation. Model/source coordinators own validation and replacement. ZIP export still syncs its completed staged archive.

`ArchivePageStore` supplies bounded reservations, request coalescing, cached-file LRU, and idempotent file leases. Pending waiters pin an entry until they acquire it, avoiding eviction between shared extraction completion and lease delivery. Clearing advances an epoch, cancels pending extractions and retires leased files. `ArchivePageSession` identifies an immutable chapter generation; URL convenience calls fingerprint each time. Source-archive/chapter deletion policy stays with Melloku.

The creation API now supports directory assets and recursive enumeration, including empty directories and download metadata. Streamed progress is synchronous and optional. `ZipMelloConsumers` isolates ComicInfo/local-comic selection, model/source extraction convenience, and native dictionary preflight from the archive codec.

The vendored reader detects a streamed ZIP64 descriptor from local size reservation even when final central sizes fit 32 bits. Descriptor metadata must agree with the central record. ZIP64 effective central fields now preserve valid zero sizes/offsets. Independent Python fixtures cover those cases and signed/unsigned descriptors; reference clones remain unchanged.
