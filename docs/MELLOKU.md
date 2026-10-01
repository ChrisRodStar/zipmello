# Melloku integration

Melloku's source-page and `.aix` installation calls use ZipMello. Local-comic, download, page-cache, model, and dictionary adapters are available for application services to adopt.

Melloku keeps a library-only snapshot at `Shared/Vendor/ZipMello`. Refresh it from the ZipMello root:

```sh
python3 Tools/sync-melloku.py --melloku /path/to/Melloku
```

The sync tool replaces managed library and engine directories. It leaves Melloku's package manifest and call sites untouched. Tests use ZIPFoundation to construct independent and malformed archives.

Application services own security-scoped access, image decoding, native dictionary conversion, model compilation, database changes, and installation replacement. See [architecture](ARCHITECTURE.md), [compatibility audit](COMPATIBILITY-AUDIT.md), and [remaining work](TODO.md).
