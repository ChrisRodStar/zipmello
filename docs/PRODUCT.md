# ZipMello

Christopher needs one archive implementation for Melloku’s iOS 27 and macOS 27 source packages, local comics, downloaded chapters, reader pages, model packages, and dictionary imports.

The package indexes ZIP files and memory buffers, reads and extracts members under explicit budgets, and creates ZIP/CBZ archives containing pages and metadata. Failed or cancelled operations leave incomplete output unpublished.

The library owns ZIP mechanics and handle lifetimes. Callers own source authentication, security-scoped document access, image processing, dictionary conversion, database transactions, and user-facing settings.

The package is developed locally; Melloku vendors a library-only snapshot. No backend or UI is needed. Continue optimization only when representative workload measurements demonstrate a benefit without increasing corruption, cancellation, or compatibility failures.
