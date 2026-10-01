# Fixture provenance

These are archive-mechanics fixtures, not private user data or a complete Melloku integration test.

- `source`: Melloku's existing `ModernPayload` test Wasm and source manifest. Small test payload, not a production source extension. Copied from `Shared/Tests/MellokuSourceEngineTests/Fixtures/ModernPayload` on 2026-10-01.
- `comic`: five published JPEG pages from Pepper & Carrot episode 1, The Potion of Flight. Art and scenario: David Revoy; English translation: Butterfly; proofreading: Hedgehog brown and Yellow bird. [Official comic](https://www.peppercarrot.com/en/webcomic/ep01_Orange.html), [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). Archive packaging preserves the page bytes.
- `comic128`: those five pages repeated to create a 128-entry workload. This is an artificial larger chapter, not a second real comic.
- `dictionary`: Yomitan's valid-dictionary1 test fixture at revision `67db60ddc2cbd7b5172d777c117e3201d7ddff0f`. [Source](https://github.com/yomidevs/yomitan/tree/67db60ddc2cbd7b5172d777c117e3201d7ddff0f/test/data/dictionaries/valid-dictionary1). GPL-3.0-or-later; see YOMITAN-LICENSE. Used only as benchmark data, not linked into the library.
- `model`: Apple's DepthAnythingV2SmallF16.mlpackage, revision `cfef6f6f2a70783dedc0bfae40cecbc2052285d3`, plus its model card. [Apple model repository](https://huggingface.co/apple/coreml-depth-anything-v2-small). Apache-2.0 as stated by the model card. Approximately 50 MB; the benchmark extracts the files and never loads, compiles, or runs the model.

`manifest.json` records byte counts and SHA-256 for the fixtures used in a run. Downloaded model files, repeated pages, and generated ZIPs are ignored by Git. Recreate with `python3 Benchmarks/prepare-fixtures.py`; compare payload hashes with the recorded manifest. The comic server has no revision URL, so its hashes are required to detect changed pages.

`dictionary4000` is generated dictionary-shaped JSON: 4,000 distinct term-bank files. It is a stress workload for indexing, directory creation, and file publication, not a dictionary accepted by every importer. Its exact payload generation is in `prepare-fixtures.py`.
