# Benchmark Fixture Attribution & License

## Pepper & Carrot

The visual pages in this directory originate from:
- **Title**: *Pepper & Carrot* — Episode 1: "The Potion of Flight"
- **Original Version**: English (original)
- **Author**: David Revoy (Scenario & Art)
- **Contributors**: Amireeti & Alex Gryson (proofreading)
- **Source URL**: [https://www.peppercarrot.com/en/article234/potion-of-flight](https://www.peppercarrot.com/en/article234/potion-of-flight)
- **Official Site**: [https://www.peppercarrot.com](https://www.peppercarrot.com)
- **License**: [Creative Commons Attribution 4.0 International (CC BY 4.0)](https://creativecommons.org/licenses/by/4.0/)

### Synthetic Workload Notice
For the purposes of archive engine benchmarking, the official Episode 1 page assets (`E01P00.jpg` through `E01P04.jpg`) are packaged into CBZ (`.zip`) format alongside standard `ComicInfo.xml` metadata and sidecar description files. The benchmark runner deterministically cycles, duplicates, and renames these pages (`page_000.jpg` through `page_079.jpg`) to synthesize an 80-entry chapter workload (`PepperAndCarrot_80P.cbz`). This synthetic scaling reproduces random-access seeks, concurrent prefetching, and cache eviction pressure under realistic mobile reader file sizes without bundling hundreds of megabytes of binary data in the git repository.

This fixture license is strictly separate from the MIT license governing the ZipMello library codebase.
