# PMTiles for Zig

Read [PMTiles v3](https://github.com/protomaps/PMTiles/blob/main/spec/v3/spec.md) single-file tile archives: header, directories, tile lookup and tile bytes, from memory, a local file, or any byte source you plug in (such as HTTP range requests). Implements PMTiles v3 (read only) · Spec v0.1.0 · Conformance: **core ✓ io ✓ full ✓** (68/68)

> **Tile bytes are returned as stored.** `getTile` gives you the tile still compressed with `header.tile_compression` and doesn't parse it. Decoding MVT, PNG or other contents is up to you.

Requires Zig **0.17.0**. Standard library only: gzip is `std.compress.flate`.

## Install

> **Not released yet.** Until the first release, fetch the default branch:
> `zig fetch --save git+https://github.com/Xenoglyphiq/pmtiles-zig`

Once `v0.1.0` is tagged:

```
zig fetch --save git+https://github.com/Xenoglyphiq/pmtiles-zig#v0.1.0
```

Then in `build.zig`:

```zig
const pmtiles = b.dependency("pmtiles", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("pmtiles", pmtiles.module("pmtiles"));
exe.root_module.addImport("pmtiles_io", pmtiles.module("pmtiles_io"));
```

## Quick start

```zig
const pmtiles = @import("pmtiles");
const pmtiles_io = @import("pmtiles_io");

var file: pmtiles_io.FileSource = try .open(io, std.Io.Dir.cwd(), "tiles.pmtiles");
defer file.close();

if (try pmtiles_io.getTile(gpa, file.source(), .{ .z = 2, .x = 1, .y = 3 }, .{}, null)) |tile| {
    defer gpa.free(tile);
    // tile bytes, still compressed with the archive's tile_compression
}

const metadata = try pmtiles_io.readMetadata(gpa, file.source(), .{}, null);
defer gpa.free(metadata);
```

Every allocating call takes the allocator first; the caller owns and frees the result.

## Examples

Run all three with `zig build examples`. The third needs network access.

### 1. Print an archive's header (`examples/inspect_archive.zig`)
```zig
var buf: [pmtiles.header_len]u8 = undefined;
const n = try file.readPositionalAll(io, &buf, 0);
const h = try pmtiles.decodeHeader(buf[0..n], &diag);
std.debug.print("zooms {d}-{d}, tile type {s}\n", .{
    h.min_zoom, h.max_zoom, std.enums.tagName(pmtiles.TileType, h.tile_type) orelse "unknown",
});
```

### 2. Fetch one tile by z/x/y (`examples/fetch_one_tile.zig`)
```zig
var file: pmtiles_io.FileSource = try .open(io, std.Io.Dir.cwd(), path);
defer file.close();
if (try pmtiles_io.getTile(gpa, file.source(), .{ .z = 2, .x = 1, .y = 3 }, .{}, &diag)) |bytes| {
    defer gpa.free(bytes);
    std.debug.print("{d} bytes\n", .{bytes.len});
} else std.debug.print("not found\n", .{});
```

### 3. Read metadata over HTTP (`examples/remote_metadata.zig`)
```zig
var client: std.http.Client = .{ .allocator = gpa, .io = io };
defer client.deinit();
var http: HttpSource = .{ .client = &client, .url = "https://pmtiles.io/protomaps(vector)ODbL_firenze.pmtiles" };
const metadata = try pmtiles_io.readMetadata(gpa, http.source(), .{}, &diag);
```
`HttpSource` lives in the example: a complete `Source` on `std.http.Client`, one `Range` request per read. It sends `Accept-Encoding: identity`, because some servers otherwise apply the range to a gzip-encoded copy of the file and return the wrong bytes, and it still works with servers that ignore `Range`.

## API

| Function | Spec operation | Module |
|---|---|---|
| `decodeHeader(bytes, diag) Error!Header` | `decode_header` | `pmtiles` |
| `decodeDirectory(gpa, bytes, opts, diag) Error![]Entry` (input already decompressed) | `decode_directory` | `pmtiles` |
| `zxyToTileId(coord, diag) Error!u64` | `zxy_to_tile_id` | `pmtiles` |
| `tileIdToZxy(tile_id, diag) Error!TileCoord` | `tile_id_to_zxy` | `pmtiles` |
| `findEntry(entries, tile_id) ?Entry` | `find_entry` | `pmtiles` |
| `getTile(gpa, source, coord, opts, diag) Error!?[]u8` | `get_tile` | `pmtiles_io` |
| `readMetadata(gpa, source, opts, diag) Error![]u8` (unparsed JSON) | `read_metadata` | `pmtiles_io` |
| `Reader.init(gpa, source, opts, diag)`, then `reader.getTile(gpa, coord, diag)` | `get_tile` on an open archive | `pmtiles_io` |

`Header` fields use the spec's snake_case names; `bounds` and `center` are `BBox` and `LonLat` in degrees. Header counts stored as 0 are `null`. `Compression` and `TileType` are open enums (`enum(u8) { …, _ }`): values outside the spec's table keep their raw byte, and `std.enums.tagName` returns `null` for them.

`getTile` and `readMetadata` are stateless: each call reads the header and the root directory again. For many lookups on one archive, open a `Reader`: it reads the header and root directory once, then each `getTile` reads only leaf directories and the tile. It returns the same tiles and errors, except that header and root errors come from `init`. Call `deinit` when done.

### Sources

| Source | Backed by |
|---|---|
| `MemorySource.init(bytes)` | bytes already in memory (they must outlive the source) |
| `FileSource.open(io, dir, path)` | a local file, read with positional reads; call `close` |
| your own | any `Source{ .ptr, .vtable }` whose `readRange(ptr, gpa, offset, len)` returns up to `len` bytes |

A source returns up to `len` bytes, fewer only when it ends first. A short read means the archive points past its own end, which is `pmtiles.truncated`. A failed read (`error.ReadFailed`) is `pmtiles.source_failed`.

### Internal compression

| Compression | Supported |
|---|---|
| `none` | yes |
| `gzip` | yes (`std.compress.flate`; the CRC and length in the gzip footer are checked) |
| `brotli`, `zstd` | no: `pmtiles.unsupported_compression` |
| `unknown`, unknown raw values | no: `pmtiles.unsupported_compression` |

A gzip stream that doesn't decompress is `pmtiles.invalid_directory` for a directory and `pmtiles.truncated` for the metadata.

## Limits and errors

| Limit | Default | Option name |
|---|---|---|
| Entries in one directory | 1,000,000 | `Options.max_directory_entries` |
| One directory's bytes, compressed and decompressed | 16 MiB | `Options.max_directory_bytes` |
| Leaf directories followed (root is depth 0) | 4 | `Options.max_leaf_depth` |
| Metadata bytes, compressed and decompressed | 16 MiB | `Options.max_metadata_bytes` |

Errors are the error set `pmtiles.Error`, whose names are the spec's kinds: `InvalidInput`, `Unsupported`, `LimitExceeded` and `Io` (plus Zig's `OutOfMemory`). The core module never returns `Io`. Pass a `*pmtiles.Diagnostics` to get the stable `code` (such as `pmtiles.bad_magic`) and, where known, the byte `offset` (`decodeDirectory` reports the varint that failed). Full list: spec §3.

`decodeDirectory` checks the entry count against the limit before allocating, and allocates nothing for a count the input is too short to hold. Sums of ids and offsets are checked, so a hostile archive can't overflow them. A missing tile is `null`, not an error.

## Modules

| Module | Layer | Needs |
|---|---|---|
| `pmtiles` | core | nothing beyond the standard library; no I/O |
| `pmtiles_io` | io | `std.Io` for `FileSource`, `std.compress.flate` for gzip |

`pmtiles_io` re-exports `Error`, `Diagnostics`, `Options`, `TileCoord` and `Compression`.

## Development

| Command | What |
|---|---|
| `zig build test` | Unit tests |
| `zig build test --fuzz=1M` | Fuzz `decodeHeader`, `decodeDirectory`, and `getTile` / `Reader` / `readMetadata` on mutated archives |
| `zig build conformance` | Every case in `.spec/conformance/manifest.json` (io cases through both `FileSource` and `MemorySource`) |
| `zig build examples` | The three canonical examples |
| `zig build bench [-- <dir>]` | `getTile` and `Reader` timings on `.spec/bench/` (always ReleaseFast) |

## Performance

| Benchmark | Reference | This port | Ratio |
|---|---|---|---|
| get_tile, 10,000 lookups | Rust `pmtiles` | — | — |

Recorded before v0.1.0.

## License

MIT OR Apache-2.0
