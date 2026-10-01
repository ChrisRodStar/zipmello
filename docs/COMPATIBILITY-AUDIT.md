# Melloku and Aidoku compatibility audit

Reviewed October 1, 2026 against the local Melloku, Aidoku, and ZipMello checkouts. This is a source and roadmap audit; it does not establish app integration, device performance, or complete ZIP format compatibility.

ZipMello is not yet a complete replacement for the archive operations Melloku uses today or plans to inherit from Aidoku. Its bounded, CRC-checked member reads, file extraction, ordered creation, and cached archive indexes cover the core operations. The remaining work includes both library APIs and Melloku consumer adapters.

## Current Melloku blockers

| Consumer | Existing behavior | ZipMello coverage and gap |
| --- | --- | --- |
| Remote source archive pages | Opens downloaded `Data`; reads an image or UTF-8 TXT/Markdown member. Limits the download to 64,000,000 bytes and the selected member to 32,000,000 bytes. | Member reads work, but `ArchiveReader.open` accepts only file URLs. Add a bounded byte-backed reader or a scoped temporary-file adapter. Preserve the existing network/challenge flow and consumer budgets. |
| Source `.aix` installation | Extracts all entries into staging, including directories and nested `Payload/`, then validates manifest/Wasm and replaces an installed source with rollback. | Single-file extraction works. Whole-tree extraction, parent creation, directory entries, and consumer staging/commit integration are missing. |

Evidence: [SourcePageResolver.swift](/Users/chris/Desktop/Workspace/Products/Melloku/Shared/Sources/MellokuSourceEngine/Host/SourcePageResolver.swift:21), [SourceRuntimeRegistry.swift](/Users/chris/Desktop/Workspace/Products/Melloku/Shared/Sources/MellokuSourceEngine/Core/SourceRuntimeRegistry.swift:161), [Shared Package.swift](/Users/chris/Desktop/Workspace/Products/Melloku/Shared/Package.swift:18).

Melloku still depends on ZIPFoundation directly. These are the two direct production consumers found in `Shared/Sources`; test fixture creation is additional migration work. ZipMello has not been wired into the app.

## Required coverage for Aidoku parity and Melloku stages

| Flow | What must be supported | Current status |
| --- | --- | --- |
| Local CBZ/ZIP import | Natural page ordering; nested paths; hidden-file and description filtering; images plus TXT/Markdown; ComicInfo lookup; cover extraction; chapter file ownership. | Listing, bytes, and member extraction exist. Page selection/order, ComicInfo parsing, cover rules, import collision handling, and shared-file ownership need Melloku adapters. |
| Filename compatibility | Exact match first, then safe handling of leading `./`, case variations, and percent-encoded names. | Missing. Lookup is exact; opening an archive containing `./page` currently fails path validation. |
| Download compression/export | ZIP a chapter directory without its parent, including page descriptions and ComicInfo; preserve deterministic order; expose useful progress; publish only successful output. | Ordered explicit assets and staged ZIP creation exist. Recursive directory enumeration and progress are missing; the CLI includes only immediate regular files. |
| Reader images and text | Lazy member access; extracted-page memoization; session cleanup; cancellation; file leases that delay deletion while in use. | Archive index caching and bounded parallel reads exist. Extracted-file caching and app leases do not. UTF-8/Markdown interpretation belongs in the reader adapter. |
| CoreML model installation | Extract nested `.mlpackage` directories; stage installation; validate the package/configuration before replacement. | Nested member names are supported, but complete directory extraction and model installation integration are missing. |
| Dictionary installation | Resource- and CRC-checked ZIP preflight before invoking the native dictionary importer; bounded memory for thousands of members. | Open validates directory metadata/budgets; CRC is checked only when reading/extracting a member. A streaming validate-only operation is missing. The native importer remains necessary. |

Evidence:

- [Aidoku local import and listing](/Users/chris/Desktop/Workspace/External/Aidoku/Aidoku/Core/Sources/BuiltIn/Local/LocalFileManager.swift:60), [ComicInfo loading](/Users/chris/Desktop/Workspace/External/Aidoku/Aidoku/Core/Downloads/Models/ComicInfo.swift:378), [Melloku local-source stage](/Users/chris/Desktop/Workspace/Products/Melloku/docs/parity/04-local-and-self-hosted-sources.md).
- [Aidoku tolerant entry lookup](/Users/chris/Desktop/Workspace/External/Aidoku/Aidoku/Extensions/ZIPFoundation/Archive.swift:17), [its regression tests](/Users/chris/Desktop/Workspace/External/Aidoku/AidokuTests/ArchiveTests.swift).
- [Aidoku export](/Users/chris/Desktop/Workspace/External/Aidoku/Aidoku/Core/Downloads/DownloadManager.swift:158), [download compression](/Users/chris/Desktop/Workspace/External/Aidoku/Aidoku/Core/Downloads/DownloadTask.swift:514), [description sidecars](/Users/chris/Desktop/Workspace/External/Aidoku/Aidoku/Core/Downloads/DownloadTask.swift:282), [Melloku downloads stage](/Users/chris/Desktop/Workspace/Products/Melloku/docs/parity/06-offline-downloads-and-archives.md).
- [Aidoku temporary page store](/Users/chris/Desktop/Workspace/External/Aidoku/Aidoku/Features/Reader/ReaderTemporaryPageStore.swift:51), [paged text](/Users/chris/Desktop/Workspace/External/Aidoku/Aidoku/Features/Reader/Readers/Text/Paged/ReaderPagedTextViewController.swift:354), [Melloku imaging stage](/Users/chris/Desktop/Workspace/Products/Melloku/docs/parity/08-image-processing-and-upscaling.md:53).
- [Aidoku source installation](/Users/chris/Desktop/Workspace/External/Aidoku/Aidoku/Core/Sources/SourceManager.swift:471), [model extraction](/Users/chris/Desktop/Workspace/External/Aidoku/Aidoku/Core/Upscaling/ModelManager.swift:51).
- [Aidoku native dictionary installation](/Users/chris/Desktop/Workspace/External/Aidoku/Aidoku/Core/Dictionary/DictionaryManager.swift:267), [Melloku dictionary validation requirement](/Users/chris/Desktop/Workspace/Products/Melloku/docs/parity/09-dictionary-ocr-and-vocabulary.md:70).

## Library changes to prioritize

1. Provide bounded downloaded-byte access, either directly or through a managed spool adapter. Compare memory, latency, and cleanup for the existing remote-page workload before choosing.
2. Add a safe whole-tree extraction operation into a new staging directory. Create missing parents and empty directories; detect normalized destination collisions and file/directory conflicts; reject traversal and links; clean up partial work on failure or cancellation. Keep source/model validation and installed-directory replacement in their consumer coordinators.
3. Add optional compatible lookup. Preserve raw member identity; exact matches take precedence. Permit harmless leading `./` through deliberate intake canonicalization, then validate. Case/percent-decoded fallback must reject ambiguous matches. Never use a decoded lookup alias directly as an extraction destination.
4. Expose bounded streaming validation without retaining expanded data or writing every member to disk. Use it for dictionary CRC preflight. Reuse existing CRC/size/budget enforcement and cancellation rather than introducing a separate weaker extractor. Native dictionary conversion will still decompress its input; benchmark this additional preflight cost explicitly.
5. Add recursive folder packaging and progress contracts. Include required sidecars and nested assets; make filtering, ordering, and parent-folder policy explicit. Existing explicit asset creation can remain the underlying writer.
6. Define consumer limit profiles. Current defaults are 512 MiB physical ZIP, 250 MiB per entry, 2 GiB declared expansion, and 20,000 entries. Those differ from current source-page/source-install budgets and may reject legitimate large dictionaries, models, or comics. Limits are configurable already; collect representative fixtures before selecting larger profiles.

The bulk writer supports ZIP64 directory counts/offsets but rejects individual inputs or compressed members at the 32-bit size boundary. No inspected consumer establishes a requirement for a single member approaching 4 GiB; document the limit and add full ZIP64 member writing only if real fixtures require it.

## Melloku adapter work

Build local-comic selection/ComicInfo support, downloaded-directory export, a reader temporary-page store, source/model installation coordinators, and dictionary preflight integration. The archive session pool caches parsed indexes and open descriptors; it does not memoize extracted files or implement chapter deletion policy. Reader files need bounded storage, coalesced duplicate requests, archive-generation identity, and release/cleanup behavior integrated with downloads and local chapters.

Keep image decoding, natural page ordering, XML metadata, UTF-8/Markdown rendering, CoreML compilation, security-scoped access, network retries, and native dictionary conversion in their owning application services. They are use cases the integration must cover, not reasons to put every service into the ZIP codec.

## Verification before switching dependencies

Add consumer fixtures for memory-backed remote image/text ZIPs and existing 64,000,000/32,000,000-byte limits; flat and `Payload/` source packages; nested and empty directories; rollback/cancellation; tolerant paths and ambiguous aliases; natural image/text order and `N.desc.txt`; nested ComicInfo; recursive CBZ export and sidecars; repeated page extraction and lease-aware deletion; nested model packages; dictionary CRC preflight and large entry counts.

Extend format interoperability fixtures to cover external data descriptors, filename encodings, and ZIP64 sizes/offsets beyond the existing 65,536-entry directory test. The retained ZIPFoundation engine provides filename decoding and ZIP64 parsing, but the facade and its limits still need consumer evidence. Test case-insensitive destination collisions separately from archive-name lookup.

Measure before/after on the same real consumer fixtures, including repeated page requests, export, model extraction, and dictionary preflight plus native import. Existing library benchmarks do not establish those integrated timings.

## Features without a demonstrated requirement

No inspected production call site requires archive mutation/removal, password encryption, or symlink restoration. The inspected local importer supports CBZ and ZIP. EPUB mentions and EPUB-shaped lookup tests demonstrate path compatibility requirements, not a complete local EPUB importer; RAR/CBR names elsewhere do not establish a ZIPFoundation-backed RAR implementation. Current Melloku backup plans use JSON/binary plist and do not add a ZIP backup requirement.

No production code changed during this audit. No app, simulator, or runtime benchmarks were run for it.

## Implementation follow-up

The gaps above were implemented after this audit: memory readers/service, compatible lookup, staged whole-tree extraction, recursive export/directory assets/progress, streaming consumption/CRC validation, bounded page-store leases/sessions, local-comic/ComicInfo adapters, installation convenience, and dictionary preflight. Melloku's two production call sites now import ZipMello. Test fixture builders retain ZIPFoundation as an implementation-level dependency. See [README](/Users/chris/Desktop/Workspace/IdeasTo/zipmello/README.md) and [replacement measurements](/Users/chris/Desktop/Workspace/IdeasTo/zipmello/Benchmarks/REPLACEMENT.md) for current verification and limits. The initial audit tables describe the state before implementation.
