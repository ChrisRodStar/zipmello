# ZipMello Benchmark Suite

A standalone, reproducible SwiftPM benchmark comparing **ZipMello** against **[ZIPFoundation 0.9.20](https://github.com/weichsel/ZIPFoundation)** across access patterns specific to comic and manga readers.

The suite requires no Python, submodules, or non-Swift runtime dependencies:

```bash
# Standard 10-pair benchmark suite:
swift run --package-path Benchmarks -c release

# Machine-readable JSON output:
swift run --package-path Benchmarks -c release ZipMelloBenchmark --json

# Fast smoke run (2 pairs):
swift run --package-path Benchmarks -c release ZipMelloBenchmark --quick
```

---

## Canonical Results

Measured on Apple Silicon (Apple M3, 8 GB RAM, macOS 15, Release `-O` build, warm OS page cache):

### Head-to-Head Engine Benchmarks

| Workload | ZIPFoundation 0.9.20 | ZipMello | Median Paired Speedup | Details |
| :--- | ---: | ---: | ---: | :--- |
| **Path Lookup by Name** | 14.22 ms ± 0.04 ms | **0.26 ms ± 0.00 ms** | **54.86×** | 80 path queries; ZipMello average $O(1)$ index vs ZIPFoundation stock $O(N)$ linear scans |
| **Library Discovery** | 0.66 ms ± 0.00 ms | **0.35 ms ± 0.00 ms** | **1.93×** | Open archive + index central directory + extract cover + parse `ComicInfo.xml` |
| **In-Memory Decompression** | 5.18 ms ± 0.01 ms | **5.06 ms ± 0.00 ms** | **1.02×** | 50 page extractions from pre-parsed memory readers (`ArchiveMemoryReader` vs `Archive(data:)`) |
| **Concurrent Prefetching** | 2.87 ms ± 0.01 ms | 2.95 ms ± 0.00 ms | 0.97× | 32 simultaneous page extractions across 4 threads (4 ZIPFoundation handles vs ZipMello `.pagePrefetch` 4 lanes) |
| **Random-Access Page Reads** | 8.90 ms ± 0.02 ms | 9.52 ms ± 0.01 ms | 0.94× | 80 page extractions into materialized `Data` with pre-indexed entries |

---

## Continuous Scroll Viewport Leasing

Evaluates ZipMello's [ArchivePageStore](file:///Users/chris/Desktop/Workspace/IdeasTo/zipmello/Sources/ZipMello/ArchivePageStore.swift) simulating an active manga reader scrolling vertically through an 80-page chapter.

- **Access Pattern**: 108 viewport steps combining forward reading, small 4-page backtracks, and reverse scrolling.
- **Viewport Window**: 6 concurrent pages retained at any point.
- **Cache Bounds**: 6.0 MB maximum memory/disk budget, 24 maximum files.
- **Concurrency**: `maximumExtractions: 6`.

| Metric | Measured Value | Description |
| :--- | ---: | :--- |
| **Viewport Steps** | 108 | Total navigation steps traversed |
| **Cache Hits** | 32 | Pages served directly from cache without extraction |
| **Cache Misses** | 81 | Physical disk extractions performed |
| **Evictions** | 57 | Files safely evicted under the 6 MB / 24-file limit |
| **Peak Cached Bytes** | 6.00 MB | Logical byte budget strictly maintained |
| **Peak Disk Footprint** | 6.00 MB | Physical filesystem allocation queried via `attributesOfItem` |
| **Cache-Hit Latency** | **0.011 ms ± 0.001 ms MAD** | 11 microseconds to acquire an active lease |
| **Cache-Miss Latency** | 0.39 ms ± 0.07 ms MAD | Disk extraction + decompression time |
| **Total Traversal Time** | 273.23 ms | Complete 108-step user scroll simulation |

---

## Methodology & Fair Comparison

1. **Balanced Paired Sampling**:
   - 2 warmup pairs discarded to eliminate one-time allocator, JIT, and cache-priming artifacts.
   - 10 measured pairs alternating execution order (5 $A \to B$ rounds, 5 $B \to A$ rounds).
   - Paired speedup is computed as the median of the 10 full-precision $(T_{\text{ZF}} / T_{\text{ZM}})$ ratios.

2. **Calibrated Inner Loops**:
   - The harness calibrates a single iteration count targeting ~350 ms per sample before timing begins.
   - Both engines execute the identical number of repetitions within each pair.

3. **Pre-Indexed Lookup vs Pure Decompression**:
   - Stock ZIPFoundation performs a linear scan through its entry list for every `archive[path]`.
   - In **Random-Access Page Reads**, ZIPFoundation entries are pre-indexed into a `[String: Entry]` map outside the clock to isolate pure decompression throughput.
   - The lookup complexity difference is evaluated separately in **Path Lookup by Name**.

4. **Multi-Threaded ZIPFoundation Baseline**:
   - Rather than serializing reads on a single `Archive` handle, ZIPFoundation is provided a pool of 4 independent handles.
   - ZipMello uses `ArchiveTuning.pagePrefetch` (4 read lanes).

5. **Barrier Synchronization**:
   - In concurrent prefetch benchmarks, all 32 worker tasks wait behind a shared `ConcurrencyGate` actor.
   - Timing starts at the exact moment the barrier releases all 32 tasks, removing task-creation and thread-scheduling jitter from the measurement.

6. **Buffer Sizing & Data Materialization**:
   - Both engines decompress using 64 KB buffers (`bufferSize: 65536`).
   - Both materialize full `Data` payloads and verify CRC32.
   - Extracted `Data` is dropped on each loop iteration to prevent allocator accumulation.

7. **Independent Payload Verification**:
   - Outside the timer, all extracted page outputs are verified for bitwise parity using SHA-256 digests and exact byte counts.

---

## CLI Options

```text
Usage:
  swift run --package-path Benchmarks -c release [options]

Options:
  --json               Output machine-readable JSON results
  --quick              Run 2 measured pairs (1 A->B, 1 B->A) for fast smoke testing
  --pairs <count>      Number of measured pairs (default: 10)
  --seed <number>      Deterministic PRNG seed for page permutations (default: 0x123456789ABCDEF)
  --workload <filter>  Filter workload (random, lookup, concurrent, memory, discovery, leasing, or all)
  --fixture <path>     Path to a custom .cbz or .zip archive fixture
  --help, -h           Show this help message
```

---

## Fixture Attribution

The visual pages used in the synthetic 80-page fixture originate from:
- **Title**: *Pepper & Carrot* — Episode 1: "The Potion of Flight"
- **Author**: David Revoy (Scenario & Art)
- **Proofreading**: Amireeti & Alex Gryson
- **Source**: [https://www.peppercarrot.com/en/article234/potion-of-flight](https://www.peppercarrot.com/en/article234/potion-of-flight)
- **License**: [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/)

See [LICENSE-FIXTURES.md](Fixtures/LICENSE-FIXTURES.md) for full attribution details.
