# Toolchain and API decisions

Checked against the selected Xcode toolchain on 2026-10-01: Apple Swift 6.4 (`swiftlang-6.4.0.34.1`), target `arm64-apple-macosx27.0.0`. Both package manifests declare iOS 27/macOS 27 and Swift 6 language mode. This is a library with no SwiftUI target; default isolation is not set to MainActor.

Apple-authored agent guidance was exported temporarily with `xcrun agent skills export`. The Swift Testing guidance informed the tests. Swift Testing guidance applies to the test suite. The C bounds-safety guidance was reviewed when adding libdeflate; the upstream C sources are compiled unchanged, with no claim that they have adopted `-fbounds-safety`. UI, document-app, and App Intents guidance does not apply to this library. Temporary exports are not installed into the repository.

- [Swift Package Manager package structure](https://docs.swift.org/latest/documentation/packagemanagerdocs/introducingpackages/): use conventional `Package.swift`, `Sources/<target>`, and `Tests/<target>` layout.
- [Apple DispatchSerialQueue](https://developer.apple.com/documentation/dispatch/dispatchserialqueue): use its built-in SerialExecutor conformance instead of maintaining a custom ExecutorJob bridge. The macOS 27 SDK’s Dispatch interface confirms the initializer and conformance, including modern isolation checking.
- [Swift custom actor executors, SE-0392](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0392-custom-actor-executors.md): actor-owned archive state with an explicit serial executor.
- [Swift System FileDescriptor](https://github.com/apple/swift-system/blob/main/Sources/System/FileOperations.swift): pinned Swift System 1.8.1 provides throwing positional reads and no-follow opens. Descriptors have one immutable owner; raw descriptor values never escape the library.
- [Apple FileHandle](https://developer.apple.com/documentation/foundation/filehandle): use throwing `read(upToCount:)`, `write(contentsOf:)`, `seek(toOffset:)`, `synchronize()`, and `close()` APIs. Synchronous ZIP/file operations run on the dedicated executor; marking an operation async does not by itself make I/O nonblocking.
- [Swift Testing](https://developer.apple.com/xcode/swift-testing/): use `@Suite`, parameterized `@Test`, and exact error assertions. Fixtures have independent temporary directories for parallel execution.

The Apple Foundation updates page does not currently document a separate June 2026 archive API. The installed SDK and compiler establish API availability; this project does not invent an iOS 27-specific replacement for ZIPFoundation. No blanket `@unchecked Sendable`, `nonisolated(unsafe)`, or `@preconcurrency` suppression is used in the new library.

## Working ZIPFoundation changes

The reference submodule remains unchanged at `e7a17d57c583067eaa6659cd6d9521265b7664e9`, the latest remote development HEAD when cloned. The working copy preserves upstream MIT attribution and privacy resources.

- Apple-only Swift 6.4 manifest with iOS/macOS 27 deployment targets. Cross-platform targets and upstream test target are omitted from the working manifest.
- Deprecated compatibility overload files are removed from the working copy. Callers use throwing initializers and the current Int64-size APIs.
- ZIP64 maximum-field values are immutable. Upstream tests mutate these globals to force ZIP64 with small fixtures; production limits no longer change across concurrent archives. Adapted ZIP64 tests need an explicit fixture or injected test seam.
- The Apple compression stream is initialized explicitly instead of reading an uninitialized allocation; this also removes an allocation for the stream struct.

These changes establish a compile/test baseline. They do not constitute a complete API, pointer-safety, archive-format, or performance audit of every inherited implementation path.

## Optimization pass

- Bulk creation writes one central directory, with ZIP64 directory counts/offsets; the general upstream incremental-update API is preserved.
- Sendable offset descriptors replace actor-owned Entry values after validation. Positional readers share a descriptor without sharing a seek cursor; bounded lanes retain operation ownership through eviction/closure.
- The session pool fingerprints files and coalesces opens. Index-weight accounting is estimated, not a guaranteed process-memory limit.
- Reader input uses adopted allocated storage, output capacity is reserved under validated limits, and file writers read sequentially using Swift System.
- Writer defaults use 256 KiB buffers after the release sweep; readers retain 64 KiB/one lane, with four-lane prefetch explicitly selected.
- Optional libdeflate 1.26 at `92e6a0db9fa848d742f9eb286c92afc60f2c3dda` is pinned in an unchanged reference submodule. Its unmodified C sources and MIT license are copied into the working dependency. Whole-buffer operation is limited to 4 MiB and larger entries retain Apple streaming. SDK builds currently emit upstream integer-conversion warnings from libdeflate; these are not suppressed with unsafe compiler flags.

Benchmark-only baseline modules live in a separate package. The production library does not depend on the preserved before implementation or public benchmark datasets. Source snapshots, raw samples, hashes, buffer/concurrency sweeps, cache-bypass measurements and process RSS are documented in `Benchmarks`.

## Replacement implementation toolchain check

On October 1, 2026, exported the selected Xcode agent skills to `/tmp/zipmello-xcode-skills.7EZTsa` and read Apple's modernize-tests guidance for Swift Testing. The selected compiler is Apple Swift 6.4 (`swiftlang-6.4.0.34.1`) with iOS/macOS 27 SDKs. New worker/file APIs use Swift actors and custom `DispatchSerialQueue` executors, Swift System positional reads/writeAll/no-follow descriptors, and `Synchronization.Mutex` for idempotent lease release. The C bounds-safety skill was reviewed for applicability; this change does not adopt that extension or rewrite the upstream C codec. No SwiftUI/UI APIs were changed for the archive migration.
