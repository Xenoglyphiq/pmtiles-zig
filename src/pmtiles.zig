//! PMTiles v3 reader, core layer: decode the header and directories, map
//! z/x/y to tile ids and back, and find a tile's directory entry.
//!
//! Implements the pmtiles spec (see `.spec/spec/SPEC.md`). Everything here
//! works on in-memory bytes; reading from files, memory or HTTP and
//! decompressing internal data is the io layer (`pmtiles_io`, `src/io.zig`).

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Error kinds from the spec. `OutOfMemory` is Zig's own and never appears in
/// conformance fixtures. Details (the spec's error code and, where known, a
/// byte offset) go in `Diagnostics`. The core layer never returns `Io`.
pub const Error = error{ InvalidInput, Unsupported, LimitExceeded, Io, OutOfMemory };

/// Filled in when an operation fails, if the caller passes one.
pub const Diagnostics = struct {
    /// Stable spec error code, e.g. `"pmtiles.bad_magic"`; empty on success.
    code: []const u8 = "",
    /// Byte offset into the input, when known. For directory errors it is the
    /// start of the varint that failed.
    offset: ?u64 = null,
};

/// Limits from spec §5. Defaults match the spec.
pub const Options = struct {
    /// Maximum entries in one directory; checked before allocating entries.
    max_directory_entries: u64 = 1_000_000,
    /// Maximum bytes fetched (and, in this port, decompressed) for one directory (16 MiB).
    max_directory_bytes: u64 = 16 * 1024 * 1024,
    /// Maximum number of leaf pointers followed below the root (depth 0).
    max_leaf_depth: u32 = 4,
    /// Maximum bytes fetched (and, in this port, decompressed) for the metadata (16 MiB).
    max_metadata_bytes: u64 = 16 * 1024 * 1024,
};

/// Internal or tile compression. Open enum: unknown raw values are kept.
pub const Compression = enum(u8) { unknown = 0, none = 1, gzip = 2, brotli = 3, zstd = 4, _ };

/// Tile content type. Open enum: unknown raw values are kept.
pub const TileType = enum(u8) { unknown = 0, mvt = 1, png = 2, jpeg = 3, webp = 4, avif = 5, _ };

/// A WGS84 bounding box in degrees.
pub const BBox = struct {
    min_lon: f64,
    min_lat: f64,
    max_lon: f64,
    max_lat: f64,
};

/// A WGS84 position in degrees, `(lon, lat)`.
pub const LonLat = struct {
    lon: f64,
    lat: f64,
};

/// The fixed 127-byte archive header (spec §2).
pub const Header = struct {
    spec_version: u8,
    root_directory_offset: u64,
    root_directory_length: u64,
    metadata_offset: u64,
    metadata_length: u64,
    leaf_directories_offset: u64,
    leaf_directories_length: u64,
    tile_data_offset: u64,
    tile_data_length: u64,
    /// Null when the archive stores 0 ("unknown").
    addressed_tiles_count: ?u64,
    /// Null when the archive stores 0.
    tile_entries_count: ?u64,
    /// Null when the archive stores 0.
    tile_contents_count: ?u64,
    clustered: bool,
    internal_compression: Compression,
    tile_compression: Compression,
    tile_type: TileType,
    min_zoom: u8,
    max_zoom: u8,
    bounds: BBox,
    center_zoom: u8,
    center: LonLat,
};

/// One directory entry. `run_length == 0` means the entry points to a leaf
/// directory; otherwise it covers tile ids `tile_id .. tile_id + run_length - 1`.
pub const Entry = struct {
    tile_id: u64,
    /// Byte offset within the tile data section (tiles) or the leaf
    /// directories section (leaf pointers).
    offset: u64,
    /// Byte length.
    length: u32,
    run_length: u32,
};

/// A tile coordinate.
pub const TileCoord = struct {
    z: u8,
    x: u32,
    y: u32,
};

/// Length of the header in bytes.
pub const header_len = 127;

/// The last valid tile id (the last tile at zoom 31): `(4^32 - 1) / 3 - 1`.
pub const max_tile_id: u64 = std.math.maxInt(u64) / 3 - 1;

/// Records `code` in `diag`, if given, and returns `err`.
pub fn fail(diag: ?*Diagnostics, comptime code: []const u8, offset: ?u64, err: Error) Error {
    if (diag) |d| d.* = .{ .code = "pmtiles." ++ code, .offset = offset };
    return err;
}

fn readU64(b: []const u8, at: usize) u64 {
    return std.mem.readInt(u64, b[at..][0..8], .little);
}

fn readDegrees(b: []const u8, at: usize) f64 {
    const e7 = std.mem.readInt(i32, b[at..][0..4], .little);
    return @as(f64, @floatFromInt(e7)) / 1e7;
}

fn count(v: u64) ?u64 {
    return if (v == 0) null else v;
}

/// Spec operation `decode_header`. Decodes the first 127 bytes of an archive;
/// bytes after them are ignored.
pub fn decodeHeader(bytes: []const u8, diag: ?*Diagnostics) Error!Header {
    // Length is checked first, so short garbage is `truncated`, not `bad_magic`.
    if (bytes.len < header_len) return fail(diag, "truncated", bytes.len, error.InvalidInput);
    if (!std.mem.eql(u8, bytes[0..7], "PMTiles")) return fail(diag, "bad_magic", 0, error.InvalidInput);
    if (bytes[7] != 3) return fail(diag, "unsupported_version", 7, error.Unsupported);
    return .{
        .spec_version = bytes[7],
        .root_directory_offset = readU64(bytes, 8),
        .root_directory_length = readU64(bytes, 16),
        .metadata_offset = readU64(bytes, 24),
        .metadata_length = readU64(bytes, 32),
        .leaf_directories_offset = readU64(bytes, 40),
        .leaf_directories_length = readU64(bytes, 48),
        .tile_data_offset = readU64(bytes, 56),
        .tile_data_length = readU64(bytes, 64),
        .addressed_tiles_count = count(readU64(bytes, 72)),
        .tile_entries_count = count(readU64(bytes, 80)),
        .tile_contents_count = count(readU64(bytes, 88)),
        .clustered = bytes[96] == 1,
        .internal_compression = @fromBackingInt(@intCast(bytes[97])),
        .tile_compression = @fromBackingInt(@intCast(bytes[98])),
        .tile_type = @fromBackingInt(@intCast(bytes[99])),
        .min_zoom = bytes[100],
        .max_zoom = bytes[101],
        .bounds = .{
            .min_lon = readDegrees(bytes, 102),
            .min_lat = readDegrees(bytes, 106),
            .max_lon = readDegrees(bytes, 110),
            .max_lat = readDegrees(bytes, 114),
        },
        .center_zoom = bytes[118],
        .center = .{ .lon = readDegrees(bytes, 119), .lat = readDegrees(bytes, 123) },
    };
}

/// Reads unsigned LEB128 varints (spec §3 `decode_directory`, step 1).
const Cursor = struct {
    bytes: []const u8,
    pos: usize = 0,
    /// Start of the varint read last, for diagnostics.
    start: usize = 0,

    inline fn varint(c: *Cursor, diag: ?*Diagnostics) Error!u64 {
        // Fast path: directory values almost always fit in one or two bytes.
        c.start = c.pos; // error offsets point at the value's first byte
        if (c.pos + 1 < c.bytes.len) {
            const b0 = c.bytes[c.pos];
            if (b0 < 0x80) {
                c.pos += 1;
                return b0;
            }
            const b1 = c.bytes[c.pos + 1];
            if (b1 < 0x80) {
                c.pos += 2;
                return @as(u64, b0 & 0x7F) | @as(u64, b1) << 7;
            }
        }
        const v = try varintSlow(c.bytes, c.pos, diag);
        c.pos += v.len;
        return v.value;
    }

    const Varint = struct { value: u64, len: usize };

    /// Takes the bytes and position by value, so the cursor's address never
    /// escapes the inlined fast path and its fields can stay in registers.
    fn varintSlow(bytes: []const u8, start: usize, diag: ?*Diagnostics) Error!Varint {
        var pos = start;
        var result: u64 = 0;
        var n: u6 = 0;
        while (n < 10) : (n += 1) {
            if (pos >= bytes.len) return fail(diag, "truncated", start, error.InvalidInput);
            const byte = bytes[pos];
            pos += 1;
            // The 10th byte may only carry bit 63.
            if (n == 9 and byte > 1) return fail(diag, "varint_overflow", start, error.InvalidInput);
            result |= @as(u64, byte & 0x7F) << (7 * n);
            if (byte < 0x80) return .{ .value = result, .len = pos - start };
        }
        return fail(diag, "varint_overflow", start, error.InvalidInput);
    }
};

/// Walks the four sections after the entry count, checking every rule in
/// spec §3 in order. With `out` it also stores the entries; without it, it
/// only finds the error (used when the input is too short to hold `n`
/// entries, so nothing is allocated for it).
fn walkDirectory(cursor: *Cursor, n: u64, out: ?[]Entry, diag: ?*Diagnostics) Error!void {
    // Work on a local copy: stores into `out` could otherwise alias the
    // cursor, forcing its position through memory on every varint.
    var c = cursor.*;
    defer cursor.* = c;
    const u32_max = std.math.maxInt(u32);

    var id: u64 = 0;
    var k: u64 = 0;
    while (k < n) : (k += 1) {
        const delta = try c.varint(diag);
        // Tile ids must strictly increase (D-002).
        if (k > 0 and delta == 0) return fail(diag, "invalid_directory", c.start, error.InvalidInput);
        id = std.math.add(u64, id, delta) catch return fail(diag, "invalid_directory", c.start, error.InvalidInput);
        if (out) |e| e[@intCast(k)].tile_id = id;
    }
    k = 0;
    while (k < n) : (k += 1) {
        const run = try c.varint(diag);
        if (run > u32_max) return fail(diag, "invalid_directory", c.start, error.InvalidInput);
        if (out) |e| e[@intCast(k)].run_length = @intCast(run);
    }
    const lengths_start = c.pos;
    k = 0;
    while (k < n) : (k += 1) {
        const len = try c.varint(diag);
        if (len > u32_max) return fail(diag, "invalid_directory", c.start, error.InvalidInput);
        if (out) |e| e[@intCast(k)].length = @intCast(len);
    }
    // Offsets continue from the previous entry's length: stored ones when
    // there is `out`, otherwise re-read (already validated) by a second cursor.
    var lengths: Cursor = .{ .bytes = c.bytes, .pos = lengths_start };
    var prev_offset: u64 = 0;
    var prev_length: u64 = 0;
    k = 0;
    while (k < n) : (k += 1) {
        const v = try c.varint(diag);
        const offset = if (v == 0) blk: {
            // Nothing to continue from on the first entry (D-002).
            if (k == 0) return fail(diag, "invalid_directory", c.start, error.InvalidInput);
            break :blk std.math.add(u64, prev_offset, prev_length) catch
                return fail(diag, "invalid_directory", c.start, error.InvalidInput);
        } else v - 1;
        if (out) |e| e[@intCast(k)].offset = offset;
        prev_offset = offset;
        prev_length = if (out) |e| e[@intCast(k)].length else lengths.varint(null) catch unreachable;
    }
    // Bytes after the last offset are ignored (A2).
}

/// Spec operation `decode_directory`. Decodes an already-decompressed
/// directory into entries. The caller owns the returned slice and frees it
/// with `gpa`.
pub fn decodeDirectory(gpa: Allocator, bytes: []const u8, opts: Options, diag: ?*Diagnostics) Error![]Entry {
    var c: Cursor = .{ .bytes = bytes };
    const n = try c.varint(diag);
    // Checked before reading or allocating any entry.
    if (n > opts.max_directory_entries) return fail(diag, "directory_too_large", c.start, error.LimitExceeded);

    // Every entry takes at least 4 bytes (one per section). If the rest of the
    // input can't hold `n` entries, decoding must fail; find out how without
    // allocating, so a large `n` in a short input costs nothing.
    if (n > (bytes.len - c.pos) / 4) {
        try walkDirectory(&c, n, null, diag);
        return fail(diag, "truncated", bytes.len, error.InvalidInput); // not reached
    }
    const entries = try gpa.alloc(Entry, @intCast(n));
    errdefer gpa.free(entries);
    try walkDirectory(&c, n, entries, diag);
    return entries;
}

/// Spec operation `zxy_to_tile_id`. The Hilbert-curve tile id of `coord`.
pub fn zxyToTileId(coord: TileCoord, diag: ?*Diagnostics) Error!u64 {
    if (coord.z > 31) return fail(diag, "invalid_zoom", null, error.InvalidInput);
    const n = @as(u64, 1) << @intCast(coord.z);
    if (coord.x >= n or coord.y >= n) return fail(diag, "tile_out_of_range", null, error.InvalidInput);

    // Tiles at all lower zooms: (4^z - 1) / 3.
    var acc: u64 = ((@as(u64, 1) << @intCast(2 * @as(u32, coord.z))) - 1) / 3;
    var x: u64 = coord.x;
    var y: u64 = coord.y;
    var s: u64 = n >> 1;
    while (s > 0) : (s >>= 1) {
        const rx: u64 = @intFromBool(x & s != 0);
        const ry: u64 = @intFromBool(y & s != 0);
        acc += s * s * ((3 * rx) ^ ry);
        rotate(n, &x, &y, rx, ry);
    }
    return acc;
}

fn rotate(n: u64, x: *u64, y: *u64, rx: u64, ry: u64) void {
    if (ry == 0) {
        if (rx == 1) {
            x.* = n - 1 - x.*;
            y.* = n - 1 - y.*;
        }
        std.mem.swap(u64, x, y);
    }
}

/// Spec operation `tile_id_to_zxy`. Inverse of `zxyToTileId`.
pub fn tileIdToZxy(id: u64, diag: ?*Diagnostics) Error!TileCoord {
    if (id > max_tile_id) return fail(diag, "invalid_zoom", null, error.InvalidInput);
    var acc: u64 = 0;
    var z: u6 = 0;
    while (true) : (z += 1) {
        const tiles = @as(u64, 1) << (2 * z);
        if (id - acc < tiles) {
            var t = id - acc;
            const n = @as(u64, 1) << z;
            var x: u64 = 0;
            var y: u64 = 0;
            var s: u64 = 1;
            while (s < n) : (s *= 2) {
                const rx = 1 & (t / 2);
                const ry = 1 & (t ^ rx);
                rotate(s, &x, &y, rx, ry);
                x += s * rx;
                y += s * ry;
                t /= 4;
            }
            return .{ .z = z, .x = @intCast(x), .y = @intCast(y) };
        }
        acc += tiles;
    }
}

/// Spec operation `find_entry`. Binary-searches `entries` (sorted by
/// `tile_id`) for the entry covering `tile_id`. Absence is normal, so it
/// returns null rather than an error.
pub fn findEntry(entries: []const Entry, tile_id: u64) ?Entry {
    var lo: usize = 0;
    var hi: usize = entries.len; // search [lo, hi)
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const id = entries[mid].tile_id;
        if (id < tile_id) {
            lo = mid + 1;
        } else if (id > tile_id) {
            hi = mid;
        } else return entries[mid];
    }
    // `lo` is the first entry above the target; the one before is the last below it.
    if (lo == 0) return null;
    const e = entries[lo - 1];
    // A leaf pointer covers every id up to the next entry (D-003).
    if (e.run_length == 0 or tile_id - e.tile_id < e.run_length) return e;
    return null;
}

// ---------------------------------------------------------------------------
// Unit tests. The conformance runner (`zig build conformance`) is the real
// test suite; these cover the spec's vectors, open enums and a few internals.
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Appends `v` as an unsigned LEB128 varint. Test helper.
pub fn appendVarint(gpa: Allocator, list: *std.ArrayList(u8), v: u64) Allocator.Error!void {
    var u = v;
    while (u >= 0x80) : (u >>= 7) try list.append(gpa, @as(u8, @truncate(u)) | 0x80);
    try list.append(gpa, @intCast(u));
}

/// Encodes `entries` as an uncompressed directory, storing every offset
/// explicitly unless it continues from the previous entry. Test helper.
pub fn encodeDirectory(gpa: Allocator, entries: []const Entry) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try appendVarint(gpa, &out, entries.len);
    var last: u64 = 0;
    for (entries) |e| {
        try appendVarint(gpa, &out, e.tile_id - last);
        last = e.tile_id;
    }
    for (entries) |e| try appendVarint(gpa, &out, e.run_length);
    for (entries) |e| try appendVarint(gpa, &out, e.length);
    for (entries, 0..) |e, k| {
        const continues = k > 0 and e.offset == entries[k - 1].offset +| entries[k - 1].length;
        try appendVarint(gpa, &out, if (continues) 0 else e.offset + 1);
    }
    return out.toOwnedSlice(gpa);
}

fn testHeader() [header_len]u8 {
    var b: [header_len]u8 = @splat(0);
    @memcpy(b[0..7], "PMTiles");
    b[7] = 3;
    std.mem.writeInt(u64, b[8..16], 127, .little);
    std.mem.writeInt(u64, b[72..80], 5, .little);
    b[96] = 1;
    b[97] = 2;
    b[98] = 1;
    b[99] = 1;
    b[100] = 0;
    b[101] = 14;
    std.mem.writeInt(i32, b[102..106], -742590000, .little);
    std.mem.writeInt(i32, b[106..110], 404770000, .little);
    std.mem.writeInt(i32, b[110..114], -737000000, .little);
    std.mem.writeInt(i32, b[114..118], 409170000, .little);
    b[118] = 3;
    std.mem.writeInt(i32, b[119..123], -739800000, .little);
    std.mem.writeInt(i32, b[123..127], 407500000, .little);
    return b;
}

test "decode_header: fields, counts and degrees" {
    const b = testHeader();
    const h = try decodeHeader(&b, null);
    try testing.expectEqual(@as(u64, 127), h.root_directory_offset);
    try testing.expectEqual(@as(?u64, 5), h.addressed_tiles_count);
    try testing.expectEqual(@as(?u64, null), h.tile_entries_count);
    try testing.expect(h.clustered);
    try testing.expectEqual(Compression.gzip, h.internal_compression);
    try testing.expectEqual(TileType.mvt, h.tile_type);
    try testing.expectEqual(@as(u8, 14), h.max_zoom);
    try testing.expectEqual(@as(f64, -74.259), h.bounds.min_lon);
    try testing.expectEqual(@as(f64, 40.917), h.bounds.max_lat);
    try testing.expectEqual(@as(f64, -73.98), h.center.lon);
}

test "decode_header: unknown enum values are kept" {
    var b = testHeader();
    b[97] = 7;
    b[99] = 42;
    const h = try decodeHeader(&b, null);
    try testing.expectEqual(@as(u8, 7), @backingInt(h.internal_compression));
    try testing.expectEqual(@as(?[:0]const u8, null), std.enums.tagName(Compression, h.internal_compression));
    try testing.expectEqual(@as(u8, 42), @backingInt(h.tile_type));
}

test "decode_header: error order" {
    var diag: Diagnostics = .{};
    // Short garbage is truncated, not bad_magic.
    try testing.expectError(error.InvalidInput, decodeHeader("NOPEs\x00\x03", &diag));
    try testing.expectEqualStrings("pmtiles.truncated", diag.code);
    var b = testHeader();
    b[6] = 'z';
    try testing.expectError(error.InvalidInput, decodeHeader(&b, &diag));
    try testing.expectEqualStrings("pmtiles.bad_magic", diag.code);
    b = testHeader();
    b[7] = 2;
    try testing.expectError(error.Unsupported, decodeHeader(&b, &diag));
    try testing.expectEqualStrings("pmtiles.unsupported_version", diag.code);
}

test "zxy_to_tile_id and tile_id_to_zxy: spec vectors" {
    const vectors = [_]struct { TileCoord, u64 }{
        .{ .{ .z = 0, .x = 0, .y = 0 }, 0 },
        .{ .{ .z = 1, .x = 0, .y = 0 }, 1 },
        .{ .{ .z = 1, .x = 0, .y = 1 }, 2 },
        .{ .{ .z = 1, .x = 1, .y = 1 }, 3 },
        .{ .{ .z = 1, .x = 1, .y = 0 }, 4 },
        .{ .{ .z = 2, .x = 0, .y = 0 }, 5 },
        .{ .{ .z = 3, .x = 0, .y = 0 }, 21 },
        .{ .{ .z = 12, .x = 3423, .y = 1763 }, 19078479 },
        .{ .{ .z = 31, .x = 2147483647, .y = 0 }, max_tile_id },
    };
    for (vectors) |v| {
        try testing.expectEqual(v[1], try zxyToTileId(v[0], null));
        try testing.expectEqual(v[0], try tileIdToZxy(v[1], null));
    }
}

test "tile ids: range errors" {
    var diag: Diagnostics = .{};
    try testing.expectError(error.InvalidInput, zxyToTileId(.{ .z = 32, .x = 0, .y = 0 }, &diag));
    try testing.expectEqualStrings("pmtiles.invalid_zoom", diag.code);
    try testing.expectError(error.InvalidInput, zxyToTileId(.{ .z = 3, .x = 8, .y = 0 }, &diag));
    try testing.expectEqualStrings("pmtiles.tile_out_of_range", diag.code);
    try testing.expectError(error.InvalidInput, tileIdToZxy(max_tile_id + 1, &diag));
    try testing.expectEqualStrings("pmtiles.invalid_zoom", diag.code);
}

test "decode_directory: round-trips explicit and continued offsets" {
    const gpa = testing.allocator;
    const want = [_]Entry{
        .{ .tile_id = 5, .offset = 0, .length = 10, .run_length = 1 },
        .{ .tile_id = 6, .offset = 10, .length = 20, .run_length = 3 },
        .{ .tile_id = 100, .offset = 300, .length = 7, .run_length = 0 },
    };
    const bytes = try encodeDirectory(gpa, &want);
    defer gpa.free(bytes);
    const got = try decodeDirectory(gpa, bytes, .{}, null);
    defer gpa.free(got);
    try testing.expectEqualSlices(Entry, &want, got);
}

test "decode_directory: errors and limits" {
    const gpa = testing.allocator;
    var diag: Diagnostics = .{};
    try testing.expectError(error.InvalidInput, decodeDirectory(gpa, "\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\x01", .{}, &diag));
    try testing.expectEqualStrings("pmtiles.varint_overflow", diag.code);
    // A 10th byte of 1 carries bit 63 and is fine.
    try testing.expectError(error.LimitExceeded, decodeDirectory(gpa, "\xff\xff\xff\xff\xff\xff\xff\xff\xff\x01", .{}, &diag));
    try testing.expectEqualStrings("pmtiles.directory_too_large", diag.code);
    try testing.expectError(error.InvalidInput, decodeDirectory(gpa, &.{ 2, 5, 0, 1, 1, 1, 1, 1, 0 }, .{}, &diag));
    try testing.expectEqualStrings("pmtiles.invalid_directory", diag.code);
    try testing.expectEqual(@as(?u64, 2), diag.offset);
    try testing.expectError(error.InvalidInput, decodeDirectory(gpa, &.{ 1, 5, 1, 1, 0 }, .{}, &diag));
    try testing.expectEqualStrings("pmtiles.invalid_directory", diag.code);
    try testing.expectError(error.LimitExceeded, decodeDirectory(gpa, &.{ 3, 1, 1, 1 }, .{ .max_directory_entries = 2 }, &diag));
    try testing.expectEqualStrings("pmtiles.directory_too_large", diag.code);
    // A huge count in a short input is caught without allocating for it.
    try testing.expectError(error.InvalidInput, decodeDirectory(testing.failing_allocator, &.{ 0xc0, 0x84, 0x3d, 1 }, .{}, &diag));
    try testing.expectEqualStrings("pmtiles.truncated", diag.code);
    // ...and an earlier error in that input still wins over truncation.
    try testing.expectError(error.InvalidInput, decodeDirectory(testing.failing_allocator, &.{ 0xc0, 0x84, 0x3d, 1, 0 }, .{}, &diag));
    try testing.expectEqualStrings("pmtiles.invalid_directory", diag.code);
    const empty = try decodeDirectory(gpa, &.{0}, .{}, null);
    try testing.expectEqual(@as(usize, 0), empty.len);
}

test "find_entry: exact, runs, leaf pointers, absence" {
    const entries = [_]Entry{
        .{ .tile_id = 1, .offset = 0, .length = 1, .run_length = 1 },
        .{ .tile_id = 2, .offset = 1, .length = 1, .run_length = 3 },
        .{ .tile_id = 10, .offset = 0, .length = 50, .run_length = 0 },
        .{ .tile_id = 40, .offset = 2, .length = 1, .run_length = 1 },
    };
    try testing.expectEqual(@as(?Entry, null), findEntry(&entries, 0));
    try testing.expectEqual(entries[0], findEntry(&entries, 1).?);
    try testing.expectEqual(entries[1], findEntry(&entries, 4).?);
    try testing.expectEqual(@as(?Entry, null), findEntry(&entries, 5));
    try testing.expectEqual(entries[2], findEntry(&entries, 39).?);
    try testing.expectEqual(entries[3], findEntry(&entries, 40).?);
    try testing.expectEqual(@as(?Entry, null), findEntry(&entries, 41));
    try testing.expectEqual(@as(?Entry, null), findEntry(&.{}, 7));
}

fn expectDeclared(err: Error, diag: Diagnostics) !void {
    try testing.expect(err != error.Io);
    if (err != error.OutOfMemory) try testing.expect(diag.code.len > 0);
}

test "fuzz: decode_header never crashes and reports a code" {
    try testing.fuzz({}, fuzzHeader, .{});
}

fn fuzzHeader(context: void, smith: *testing.Smith) !void {
    _ = context;
    var buf: [160]u8 = undefined;
    const len = smith.valueRangeAtMost(u16, 0, buf.len);
    smith.bytes(buf[0..len]);
    // Usually start from a valid prefix, so the fuzzer reaches past the magic.
    if (len >= 8 and smith.boolWeighted(1, 3)) {
        @memcpy(buf[0..7], "PMTiles");
        buf[7] = 3;
    }
    var diag: Diagnostics = .{};
    _ = decodeHeader(buf[0..len], &diag) catch |err| {
        try testing.expect(err == error.InvalidInput or err == error.Unsupported);
        try expectDeclared(err, diag);
        return;
    };
    try testing.expect(len >= header_len);
}

test "fuzz: decode_directory never crashes, and what it accepts re-encodes" {
    try testing.fuzz({}, fuzzDirectory, .{});
}

fn fuzzDirectory(context: void, smith: *testing.Smith) !void {
    _ = context;
    var buf: [512]u8 = undefined;
    const len = smith.valueRangeAtMost(u16, 0, buf.len);
    smith.bytes(buf[0..len]);
    const max_entries = smith.valueRangeAtMost(u64, 0, 200);

    const gpa = testing.allocator;
    var diag: Diagnostics = .{};
    const entries = decodeDirectory(gpa, buf[0..len], .{ .max_directory_entries = max_entries }, &diag) catch |err| {
        try testing.expect(err == error.InvalidInput or err == error.LimitExceeded);
        try expectDeclared(err, diag);
        return;
    };
    defer gpa.free(entries);
    try testing.expect(entries.len <= max_entries);
    for (entries[0..entries.len -| 1], 0..) |e, k| try testing.expect(e.tile_id < entries[k + 1].tile_id);
    // Whatever decodes re-encodes to a directory that decodes to the same entries.
    const again = try encodeDirectory(gpa, entries);
    defer gpa.free(again);
    const back = try decodeDirectory(gpa, again, .{ .max_directory_entries = max_entries }, null);
    defer gpa.free(back);
    try testing.expectEqualSlices(Entry, entries, back);
    // find_entry agrees with a linear scan.
    const target = if (entries.len > 0)
        entries[smith.index(entries.len)].tile_id +| smith.valueRangeAtMost(u8, 0, 4)
    else
        smith.value(u64);
    try testing.expectEqual(linearFind(entries, target), findEntry(entries, target));
}

fn linearFind(entries: []const Entry, tile_id: u64) ?Entry {
    var below: ?Entry = null;
    for (entries) |e| {
        if (e.tile_id == tile_id) return e;
        if (e.tile_id < tile_id) below = e;
    }
    const e = below orelse return null;
    return if (e.run_length == 0 or tile_id - e.tile_id < e.run_length) e else null;
}
