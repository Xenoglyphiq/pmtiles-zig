# PMTiles — Spec

> Capability id: `pmtiles` · Spec version: `0.1.0` · Status: draft
> Implements: PMTiles v3, read only — https://github.com/protomaps/PMTiles/blob/main/spec/v3/spec.md
> Machine-readable contract: `capability.yaml` (this file explains it; if they disagree, fix one of them in the same PR)

## 1. Scope

Read PMTiles v3 archives: decode the header and directories, map z/x/y to tile ids, find a tile's bytes, and read the metadata, from a local file, memory, or HTTP range requests.

**In scope:** reading; leaf directories; clustered and unclustered archives; internal compression `none` and `gzip` (required), `brotli` and `zstd` (optional per port).
**Out of scope:**
- Writing archives. Not needed yet.
- Decompressing or decoding tile *contents*. Callers decide what to do with MVT, PNG or other bytes, and vector tiles are a separate library (MVT).

## 2. Types

All multi-byte integers are **little-endian**.

### `Header` (127 bytes)

| Bytes | Field | Raw type | Decoded as |
|---|---|---|---|
| 0–6 | magic | 7 bytes | must be ASCII `PMTiles` |
| 7 | `spec_version` | u8 | must be 3 |
| 8–15 | `root_directory_offset` | u64 | |
| 16–23 | `root_directory_length` | u64 | |
| 24–31 | `metadata_offset` | u64 | |
| 32–39 | `metadata_length` | u64 | |
| 40–47 | `leaf_directories_offset` | u64 | |
| 48–55 | `leaf_directories_length` | u64 | |
| 56–63 | `tile_data_offset` | u64 | |
| 64–71 | `tile_data_length` | u64 | |
| 72–79 | `addressed_tiles_count` | u64 | **absent when 0** (unknown; A1) |
| 80–87 | `tile_entries_count` | u64 | absent when 0 |
| 88–95 | `tile_contents_count` | u64 | absent when 0 |
| 96 | `clustered` | u8 | `true` when the byte is 1, else `false` |
| 97 | `internal_compression` | u8 | `Compression` |
| 98 | `tile_compression` | u8 | `Compression` |
| 99 | `tile_type` | u8 | `TileType` |
| 100 | `min_zoom` | u8 | |
| 101 | `max_zoom` | u8 | |
| 102–105, 106–109 | min lon, min lat | i32 (E7) | `bounds.min_lon`, `bounds.min_lat` = value ÷ 10⁷, in degrees |
| 110–113, 114–117 | max lon, max lat | i32 (E7) | `bounds.max_lon`, `bounds.max_lat` |
| 118 | `center_zoom` | u8 | |
| 119–122, 123–126 | center lon, lat | i32 (E7) | `center.lon`, `center.lat` |

Coordinates follow `.kit/CONVENTIONS.md` §1: degrees, `(lon, lat)`. Divide by 10⁷; don't multiply by 10⁻⁷.

### `Entry`

`tile_id` (u64), `offset` (u64, bytes), `length` (u32, bytes), `run_length` (u32).
- `run_length ≥ 1`: a **tile entry**. Tile ids `tile_id … tile_id + run_length − 1` all have the same bytes, `length` bytes at `offset` within the tile data section.
- `run_length == 0`: a **leaf pointer**. A leaf directory is `length` bytes at `offset` within the leaf directories section, and it covers every tile id from `tile_id` up to the next entry's `tile_id`.

### `Compression`, `TileType` (open enums)

| Raw | `Compression` | `TileType` |
|---|---|---|
| 0 | `unknown` | `unknown` |
| 1 | `none` | `mvt` |
| 2 | `gzip` | `png` |
| 3 | `brotli` | `jpeg` |
| 4 | `zstd` | `webp` |
| 5 | | `avif` |

Raw values outside the table are kept as `unknown(raw)` (canonical JSON `{"unknown": raw}`), not rejected.

## 3. Operations

### `decode_header` (core)
1. Fewer than 127 bytes → `pmtiles.truncated`. This is checked first, so short garbage is `truncated`, not `bad_magic`.
2. Bytes 0–6 ≠ `PMTiles` → `pmtiles.bad_magic`.
3. Byte 7 ≠ 3 → `pmtiles.unsupported_version`.
4. Decode the fields in §2. Bytes after the first 127 are ignored.

### `decode_directory` (core)
Input is the directory **already decompressed** (D-001). The layout is a sequence of unsigned LEB128 varints:

```
n                                   number of entries
delta[0..n)                         tile_id[0] = delta[0]; tile_id[i] = tile_id[i-1] + delta[i]
run_length[0..n)
length[0..n)
v[0..n)                             v = 0 (i > 0): offset[i] = offset[i-1] + length[i-1]
                                    v > 0:          offset[i] = v - 1
```

1. **Varints:** 7 bits per byte, low bits first; the high bit means more bytes follow. At most 10 bytes, and the 10th may only be 0 or 1. Anything longer or larger → `pmtiles.varint_overflow`. If the input ends inside a varint → `pmtiles.truncated`.
2. Read `n`. If `n > max_directory_entries` → `pmtiles.directory_too_large`, **before** reading or allocating any entry.
3. Read the deltas. For i > 0, `delta[i] == 0` (a repeated tile id) → `pmtiles.invalid_directory` (D-002). A tile id beyond u64 → `pmtiles.invalid_directory`.
4. Read the run lengths, then the lengths. A value above u32 → `pmtiles.invalid_directory`.
5. Read the offsets. `v == 0` on the first entry → `pmtiles.invalid_directory`, because there is no previous entry to continue from (D-002). An offset beyond u64 → `pmtiles.invalid_directory`.
6. Bytes after the last offset are ignored (A2). `n == 0` gives an empty list.

### `zxy_to_tile_id` (core)
1. `z > 31` → `pmtiles.invalid_zoom`. `x ≥ 2^z` or `y ≥ 2^z` → `pmtiles.tile_out_of_range`.
2. Tile id = `(4^z − 1) / 3`, the count of tiles at all lower zooms, plus the Hilbert-curve index of (x, y) at zoom z. That index uses the same rotate-and-flip walk as the PMTiles reference implementations. Vectors: 0/0/0 → 0, 1/0/0 → 1, 1/0/1 → 2, 1/1/1 → 3, 1/1/0 → 4, 2/0/0 → 5, 3/0/0 → 21, 12/3423/1763 → 19078479.

### `tile_id_to_zxy` (core)
Inverse of the above. Ids beyond the last zoom-31 tile, `(4^32 − 1) / 3 − 1`, → `pmtiles.invalid_zoom`.

### `find_entry` (core)
Binary search the entries, which are sorted by `tile_id`. Then:
1. An entry with `tile_id` equal to the target matches.
2. Otherwise take the last entry `e` whose `tile_id` is below the target. It matches if it's a **leaf pointer** (`run_length == 0`; D-003), or if `target − e.tile_id < e.run_length`.
3. Otherwise there is no match. The result is **absent**, not an error, because missing tiles are normal.

### `get_tile` (io)
1. Read and decode the header, using the same rules and errors as `decode_header`.
2. Compute the tile id. Coordinate errors are the same as for `zxy_to_tile_id`.
3. Read the root directory: `root_directory_length` bytes at `root_directory_offset`. A length above `max_directory_bytes` → `pmtiles.directory_too_large`. Decompress it with `internal_compression` (below) and decode it as in `decode_directory`.
4. Run `find_entry`.
   - Absent → return absent.
   - Tile entry → return `length` bytes at `tile_data_offset + offset`, **still compressed** with `tile_compression`.
   - Leaf pointer → read `length` bytes at `leaf_directories_offset + offset`, decompress, decode, and repeat from step 4.
5. The root is depth 0. Following more than `max_leaf_depth` leaf pointers → `pmtiles.leaf_depth_exceeded` (D-005).

**Decompression:** `none` and `gzip` are required. `brotli` and `zstd` are optional per port, and each port's README says which it supports. Any compression a port can't decode, including `unknown` and unknown raw values → `pmtiles.unsupported_compression`. A failed read from the source → `pmtiles.source_failed` (io only).

### `read_metadata` (io)
1. Read and decode the header.
2. `metadata_length > max_metadata_bytes` → `pmtiles.metadata_too_large`, before reading it.
3. Read `metadata_length` bytes at `metadata_offset` and decompress with `internal_compression`, as for `get_tile`.
4. Return the text as a **string**, unparsed: the archive's JSON exactly as stored. Parsing is left to the caller.

## 4. Ambiguities in the external standard

| # | Question | Our answer | Matches oracle? |
|---|---|---|---|
| A1 | Header counts of 0 | Absent ("unknown"), not zero | yes (the oracle returns 0; the meaning is the same) |
| A2 | Bytes after a directory's last offset | Ignored | yes |
| A3 | Repeated tile id, or offset "continue" (stored 0) on the first entry | `pmtiles.invalid_directory` (D-002) | no: the oracle accepts both, the second as offset −1 |
| A4 | Which entry does a leaf pointer cover? | Every id from its `tile_id` up to the next entry's (D-003) | yes |
| A5 | Varints longer than 64 bits | `pmtiles.varint_overflow` | n/a: the oracle has unbounded integers |
| A6 | Leaf nesting deeper than allowed | An error, `pmtiles.leaf_depth_exceeded` (D-005) | no: the oracle stops after 4 directory reads and returns nothing |
| A7 | Truncated *and* wrong magic | `pmtiles.truncated`: length is checked first | n/a |

## 5. Limits

| Limit | Default | Why this default |
|---|---|---|
| `max_directory_entries` | 1,000,000 | Checked before allocating entries. Real directories hold far fewer, since writers split them into leaves. |
| `max_directory_bytes` | 16 MiB | Bounds one directory fetch |
| `max_leaf_depth` | 4 | Stops cycles and deep chains in hostile archives. Real writers use 1. |
| `max_metadata_bytes` | 16 MiB | Bounds the metadata fetch |

## 6. Conformance

- Oracle: Python `pmtiles==3.8.1`.
- Levels:
  - `core`: header, directory, tile-id and find cases (55).
  - `io`: `get_tile` and `read_metadata` on the archives in `conformance/cases/archives/` (13). Ports run these against a memory or file source.
  - `full`: both.
- Fixtures come from `conformance/generate/generate.py`, which uses the oracle's own writer to build:
  - a small archive (z0–z3, with a run of identical tiles and one missing tile);
  - an archive large and irregular enough to use **leaf directories** (z0–z7).

  Errors, the decisions where we differ from the oracle, and archives the writer can't produce (uncompressed, unknown compression) are written from the spec (D-004). Every oracle result is cross-checked against a transcription of this section. Internal gzip in the archives uses deflate *stored* blocks, so regeneration is byte-identical on every platform (D-004).

## 7. The three canonical examples

1. **inspect_archive:** read the first 127 bytes of a local file, `decode_header`, and print the zooms, bounds and tile type.
2. **fetch_one_tile:** open a local file as a source, `get_tile` for a coordinate, and print the byte count or "not found".
3. **remote_metadata:** create an HTTP range source, `read_metadata`, and print the JSON.

## 8. Performance target

Reference: Rust `pmtiles` crate, `get_tile` over 10,000 pseudo-random coordinates from an in-memory source (the crate has no memory backend, so the harness implements its one-method `AsyncBackend` over a `Bytes` buffer). Input: `bench/` (added before the first port's M3). Target: within 2× of the reference.

## 9. Security notes

Archives are untrusted input.
- Every count and length is checked against a limit before allocating or fetching.
- Leaf following is bounded by `max_leaf_depth`, so a cycle can't loop forever.
- Varints are capped at 10 bytes, and all arithmetic on offsets and ids is checked.
- Tile bytes are returned as-is and are never decompressed or parsed here.

Design decisions are in `DECISIONS.md`.
