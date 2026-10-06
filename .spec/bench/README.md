# Benchmarks

| Path | What |
|---|---|
| `bench.pmtiles` | 741,440-byte archive written by the oracle: every tile z0–z8 (87,343 entries after de-duplication), with **leaf directories**. Tile contents are 16–215 deterministic bytes. |
| `coords.txt` | 10,000 lookups, one `z/x/y` per line, zooms 0–9; zoom 9 is absent from the archive, so 1,019 lookups return nothing. |
| `generate.py` | Builds both, deterministically; re-running gives identical bytes on every platform. |
| `rust/` | The reference: the Rust `pmtiles` crate (pinned `=0.24.1`) over an in-memory backend. |

**Checksum: 998434.** That's the total byte length of the tiles returned for `coords.txt`. Every harness must reproduce it, which proves it returned the right bytes and didn't just go fast. The oracle and the Rust reference both produce it.

## Method

Every port measures exactly this, so ratios are comparable:

1. Read `bench.pmtiles` fully into memory and use the port's **memory source**.
2. **One pass** = `get_tile` for all 10,000 coordinates in order, summing the lengths of the returned tiles. The sum must equal the checksum.
3. Run 3 warm-up passes, then 15 timed passes. Report the median and the minimum time per pass.
4. Use an optimized build, a monotonic clock, and a quiet machine.

The ratio is **port median ÷ reference median, measured in the same session** (interleaved rounds). The target is within 2× (`spec/SPEC.md` §8).

**Caching:** the Rust reader keeps the header and root directory after opening the archive, but not the leaf directories. A stateless `get_tile` re-reads the header and root on every call. Ports may add an explicit, caller-owned reader that caches them, and should report which they measured.

## Reference timings

```
cargo run --release --manifest-path bench/rust/Cargo.toml
```

Recorded 2026-10-06 on an Apple M5 Pro (24 GB, macOS 26.6.2), three interleaved rounds of all four harnesses in one session. Each figure is the median of the three rounds' medians; the ratio is against the reference from the same session.

| Harness | Toolchain | get_tile pass median | Ratio |
|---|---|---|---|
| Rust `pmtiles` 0.24.1 (reference) | rustc 1.99.0 | 165.1 ms | 1.00 |
| Nim `pmtiles`, stateless `getTile` | Nim 2.2.12, `-d:release` | 222.8 ms | 1.35× |
| Zig `pmtiles`, `Reader` | Zig 0.17.0, ReleaseFast | 272.7 ms | 1.65× |
| Zig `pmtiles`, stateless `getTile` | Zig 0.17.0, ReleaseFast | 280.4 ms | 1.70× |
| Swift `PMTiles`, `PMTilesReader` | Swift 6.4, `-c release` | 344.9 ms | 2.09× (misses 2×) |
| Swift `PMTiles`, stateless `getTile` | Swift 6.4, `-c release` | 359.6 ms | 2.18× (misses 2×) |

All six reproduce checksum 998434. Each port's README carries its own row.
