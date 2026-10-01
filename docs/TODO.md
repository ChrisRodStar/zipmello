# Remaining validation and application work

1. Bind the supplied local-comic, download export, page-store, model-extraction, and dictionary-preflight adapters when Melloku implements those services. Its existing source-page and source-installation production calls are migrated; the roadmap's download/reader/dictionary engines are separate application work.
2. Measure integrated reader behavior, network transfer, image decoding, disk pressure, battery and thermals on a physical iOS device or permitted Mac mini. Host measurements are archive operations, not app-wide speedups.
3. Extend the external writer/fuzz corpus, including large ZIP64 offsets/sizes, filesystem races and mid-flight cancellation/teardown under prolonged load. Current tests cover streamed signed/unsigned descriptors, local ZIP64 reservation, zero ZIP64 central values, UTF-8/CP437 paths, CRC/budgets/collisions, and consumer flows.
4. Tune installation budget profiles against Christopher's real largest dictionaries/models/comics. Larger opt-in defaults are finite allowances, not proof that every real collection fits.
5. Consider decoder/compressor reuse or more concurrency only if real workload profiles show a benefit. Bounded libdeflate remains opt-in.
6. [COMPLETED] Replace `Vendor/ZIPFoundation` with zero-dependency native Apple `Compression` / Darwin `libz` binary codec. See complete file-by-file roadmap in [ZERO-VENDOR-PLAN.md](ZERO-VENDOR-PLAN.md).

