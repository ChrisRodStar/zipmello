# Benchmarks

This separate Swift package compares ZipMello with unchanged ZIPFoundation reference sources. Normal library builds do not compile the comparison targets. References live in `Benchmarks/Reference`; the working engine lives in `Vendor/ZIPFoundation`.

From the repository root:

```sh
git submodule update --init
python3 Benchmarks/prepare-fixtures.py
swift build --package-path Benchmarks -c release
python3 Benchmarks/run-consumers.py
```

The consumer harness discards one warmup per variant, then measures five fresh processes in alternating order. It verifies CRC and output bytes. Input discovery, fixture preparation, builds, and process startup are outside timing. Results are written to `results/consumer-replacement.json`. Running the script replaces that file; preserve it first if you want to keep the recorded run.

Fixtures include a source test payload, public comic pages, a CoreML package, and generated larger comic/dictionary workloads. [Provenance, licenses, and hashes](Fixtures/README.md) document their origin. Downloaded models, repeated pages, and generated ZIPs are disposable and ignored by Git.

For the synthetic archive mechanics harness:

```sh
swift run --package-path Benchmarks -c release zipmello-benchmark Benchmarks/results/run.json
```

That harness discards one warmup and alternates seven measured rounds. It uses deterministic synthetic source, comic, dictionary, and model-sized data. It tests public APIs and direct engine operations; the latter omit wrapper overhead. Its data does not reproduce the layout or compressibility of real downloads.

Both harnesses use warm filesystem caches and execute serially. They do not measure UI responsiveness, network transfer, image decoding, battery use, or iOS device performance. [Recorded consumer results](REPLACEMENT.md) include improvements and slower operations.

Historical optimization experiments, logs, and source snapshots are preserved outside this repo in the sibling `zipmello-history-2026-10-01` directory. The ZipMello rename and older benchmark terminology remain in those records.
