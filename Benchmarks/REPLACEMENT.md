# Consumer replacement measurements

October 1, 2026. Apple M3 MacBook Air (`Mac15,12`), 8 GiB RAM, macOS 27.0 build 26A428, Apple Swift 6.4, release builds. No app or simulator was launched.

The baseline is unchanged upstream ZIPFoundation at `e7a17d57c583067eaa6659cd6d9521265b7664e9`. Each row is the median of five fresh-process measurements after one warmup for each variant; variant order alternates. Filesystem caches are warm. Input enumeration/reference bytes and process startup are outside timing. Archive open/index construction, extraction/creation/validation, and reader-cache ownership operations are inside timing. The model fixture is a real approximately 50 MB CoreML package; comic128 and dictionary4000 are generated stress sets using the documented public fixtures.

Both variants verify CRC; tree/export output bytes are checked against the input files. Byte-backed batch reads check exact expected bytes. The page baseline reproduces Aidoku's actor-owned extracted-file memoization, with CRC enabled for an equivalent validation comparison. Aidoku itself skips page CRC; these numbers do not measure that weaker configuration. ZipMello additionally provides bounded reservations, immutable generation identity, leases and staged output.

## Elapsed time

Negative time changes mean less elapsed time. These are library/adapter operations, not UI or native dictionary conversion timings.

| Operation | Upstream ms | ZipMello ms | Time change |
| --- | ---: | ---: | ---: |
| 64 small memory reads; reopen each time (source fixture) | 1.005 | 2.020 | +101.1% |
| 64 small memory reads; reopen each time (comic cover) | 0.599 | 3.834 | +539.8% |
| Extract source package tree | 0.611 | 0.662 | +8.3% |
| Extract real model package tree | 196.359 | 181.528 | -7.6% |
| Extract 4,000-entry tree | 535.525 | 339.128 | -36.7% |
| Export 128-page CBZ | 32.833 | 24.004 | -26.9% |
| Export 4,000-entry directory | 311.172 | 278.372 | -10.5% |
| Validate 4,000 entries; Apple streaming | 51.868 | 69.525 | +34.0% |
| 128 memoized page requests; 16 distinct files | 6.752 | 10.836 | +60.5% |
| 64 mixed memory reads; one comic index | 2.045 | 1.539 | -24.7% |
| 64 scattered memory reads; one 4,000-entry index | 217.289 | 23.023 | -89.4% |
| Validate 4,000 entries; bounded dictionary codec | 51.868 | 42.873 | -17.3% |

Dictionary preflight now defaults to the bounded codec choice: libdeflate only when both compressed and expanded members fit 4 MiB, otherwise Apple streaming. The rest of the library retains Apple streaming by default. The validation row measures CRC validation, not the adapter's additional small index/title read or Hoshi conversion. The targeted sweep also measured tree extraction with the bounded codec; it remains an explicit installation option rather than a universal default.

The memory service pays one worker hop and validates the whole directory for every independent response. For batch access, the immutable memory reader reuses one validated index and avoids linear upstream member searches. Melloku's current remote-page path uses the independent-response service; it does not yet cache remote ZIP responses across page requests. The faster batch result must not be presented as the app's current remote-page speedup.

The lease cache has more overhead than the simpler upstream memoization, even after removing disposable-file fsync and redundant deinit release tasks. The 128-request difference is a few milliseconds; physical-device reader/frame timing is still required. Source-tree setup is also slightly slower on this small fixture. Whole-directory work and CBZ export improved; no universal speedup is claimed.

## Peak resident memory

Process peak RSS is captured before post-timing output verification. It includes benchmark setup and any retained expected memory bytes; it is not an isolated allocator measurement.

| Operation | Upstream MiB | ZipMello MiB |
| --- | ---: | ---: |
| Extract real model package tree | 8.00 | 8.41 |
| Extract 4,000-entry tree | 14.72 | 12.06 |
| Export 128-page CBZ | 8.25 | 10.22 |
| Export 4,000-entry directory | 20.83 | 52.73 |
| 64 scattered memory reads; one 4,000-entry index | 10.23 | 11.09 |

## Verification and implementation status

- 35 Swift Testing functions, including parameterized external ZIP fixtures, passed in release and with Address Sanitizer. Cases include UTF-8/CP437 paths, signed/unsigned descriptors, local ZIP64 reservation, zero ZIP64 central fields, harmless root directory markers, traversal/links/collisions, CRC corruption, cancellation, memory budgets, recursive export, ComicInfo/text/description access, dictionary preflight, and concurrent file leases.
- All 116 Melloku shared test functions passed: 47 source-engine tests and 69 domain tests, including install rollback and remote image/text resolution.
- Both Melloku app targets compiled through XcodeBuildMCP for generic iOS device and arm64 macOS, using the final vendored snapshot. No installation or launch occurred.
- Generated CLI export passed system `unzip -t`; CLI tree extraction and validation succeeded.
- Melloku production imports ZipMello; ZIPFoundation remains the private engine and a test fixture dependency. The source/model/dictionary/reader/download adapters support the audited archive requirements, while the roadmap's unfinished application services still need to bind them.

Creation still rejects individual members at the 32-bit size boundary. No inspected app consumer requires such members, password encryption, archive mutation, or RAR. Full ZIP64 multi-gigabyte interoperability and a sustained fuzz corpus remain additional validation work. Tree staging is failure/cancellation-safe but does not promise crash-durable directory transactions.

## Reproduce

Prepare the public fixtures as documented in `Benchmarks/README.md`, then run:

```sh
swift build --package-path Benchmarks -c release --product zipmello-consumer-benchmark
python3 Benchmarks/run-consumers.py
```

Raw samples, environment and source hashes are in [consumer-replacement.json](results/consumer-replacement.json). Historical exploratory runs, tuning sweeps, and baseline snapshots were moved to the local `zipmello-history-2026-10-01` archive beside this repository. Their original source hashes and measurements are preserved there.
