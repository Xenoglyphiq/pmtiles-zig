//! PMTiles v3 reader, io layer: byte sources (memory, local file, or your
//! own, such as HTTP range requests), internal decompression, `getTile` and
//! `readMetadata`.
//!
//! Implements the io operations of the pmtiles spec (see `.spec/spec/SPEC.md`).
//! Format logic lives in the core module, `pmtiles`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const pmtiles = @import("pmtiles");

pub const Error = pmtiles.Error;
pub const Diagnostics = pmtiles.Diagnostics;
pub const Options = pmtiles.Options;
pub const TileCoord = pmtiles.TileCoord;
pub const Compression = pmtiles.Compression;

const fail = pmtiles.fail;

/// A random-access byte source: a type-erased pointer and a vtable.
///
/// Implement `read` to plug in any backend (an HTTP range client, a memory
/// map, a cache). `MemorySource` and `FileSource` are provided.
pub const Source = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const ReadError = error{ ReadFailed, OutOfMemory };

    pub const VTable = struct {
        /// Reads up to `len` bytes starting at `offset` into a new slice
        /// allocated with `gpa`, which the caller owns. Returns fewer than
        /// `len` bytes only when the source ends first (an empty slice if
        /// `offset` is at or past the end). Returns `error.ReadFailed` when
        /// the source can't serve the range. Implementations should check the
        /// range before allocating, so a hostile length can't force a large
        /// allocation.
        readRange: *const fn (ptr: *anyopaque, gpa: Allocator, offset: u64, len: u64) ReadError![]u8,
    };

    /// See `VTable.readRange`.
    pub fn readRange(s: Source, gpa: Allocator, offset: u64, len: u64) ReadError![]u8 {
        return s.vtable.readRange(s.ptr, gpa, offset, len);
    }
};

/// A source over bytes already in memory. The bytes must outlive the source.
pub const MemorySource = struct {
    bytes: []const u8,

    pub fn init(bytes: []const u8) MemorySource {
        return .{ .bytes = bytes };
    }

    pub fn source(self: *MemorySource) Source {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: Source.VTable = .{ .readRange = readRange };

    fn readRange(ptr: *anyopaque, gpa: Allocator, offset: u64, len: u64) Source.ReadError![]u8 {
        const self: *MemorySource = @ptrCast(@alignCast(ptr));
        if (offset >= self.bytes.len) return gpa.alloc(u8, 0);
        const start: usize = @intCast(offset);
        const n: usize = @intCast(@min(len, self.bytes.len - start));
        return gpa.dupe(u8, self.bytes[start..][0..n]);
    }
};

/// A source over a local file, read with positional reads (no shared seek
/// position). Call `close` when done.
pub const FileSource = struct {
    io: std.Io,
    file: std.Io.File,
    /// File length, taken when opened.
    size: u64,

    pub const OpenError = std.Io.File.OpenError || std.Io.File.LengthError;

    /// Opens `path`, relative to `dir`, for reading.
    pub fn open(io: std.Io, dir: std.Io.Dir, path: []const u8) OpenError!FileSource {
        const file = try dir.openFile(io, path, .{});
        errdefer file.close(io);
        return .{ .io = io, .file = file, .size = try file.length(io) };
    }

    pub fn close(self: *FileSource) void {
        self.file.close(self.io);
    }

    pub fn source(self: *FileSource) Source {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: Source.VTable = .{ .readRange = readRange };

    fn readRange(ptr: *anyopaque, gpa: Allocator, offset: u64, len: u64) Source.ReadError![]u8 {
        const self: *FileSource = @ptrCast(@alignCast(ptr));
        if (offset >= self.size) return gpa.alloc(u8, 0);
        const n = std.math.cast(usize, @min(len, self.size - offset)) orelse return error.ReadFailed;
        const buf = try gpa.alloc(u8, n);
        errdefer gpa.free(buf);
        const got = self.file.readPositionalAll(self.io, buf, offset) catch return error.ReadFailed;
        if (got != n) return error.ReadFailed; // the file shrank since it was opened
        return buf;
    }
};

/// Reads exactly `len` bytes at `offset`. A failed read is
/// `pmtiles.source_failed`; a short one means the archive points past its own
/// end, which is `pmtiles.truncated`.
fn readExact(gpa: Allocator, src: Source, offset: u64, len: u64, diag: ?*Diagnostics) Error![]u8 {
    const bytes = src.readRange(gpa, offset, len) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ReadFailed => return fail(diag, "source_failed", offset, error.Io),
    };
    if (bytes.len != len) {
        gpa.free(bytes);
        return fail(diag, "truncated", offset +| bytes.len, error.InvalidInput);
    }
    return bytes;
}

/// Reads and decodes the header. A source shorter than the header is
/// `pmtiles.truncated`, as for `decode_header`.
fn readHeader(gpa: Allocator, src: Source, diag: ?*Diagnostics) Error!pmtiles.Header {
    const bytes = src.readRange(gpa, 0, pmtiles.header_len) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ReadFailed => return fail(diag, "source_failed", 0, error.Io),
    };
    defer gpa.free(bytes);
    return pmtiles.decodeHeader(bytes, diag);
}

const Limited = enum { directory, metadata };

/// A corrupt or cut-off gzip stream. The spec has no code for this yet; until
/// it does, every port reports `invalid_directory` for a directory and
/// `truncated` for the metadata.
fn corrupt(what: Limited, diag: ?*Diagnostics) Error {
    return switch (what) {
        .directory => fail(diag, "invalid_directory", null, error.InvalidInput),
        .metadata => fail(diag, "truncated", null, error.InvalidInput),
    };
}

/// Decompresses internal data (`none` or `gzip`). Takes ownership of `data`.
/// Output above `limit` bytes is `directory_too_large` or
/// `metadata_too_large`, per `what`.
/// CRC-32 (IEEE), slicing-by-8: eight tables built at compile time, 8 bytes per step.
/// std.hash.Crc32 is byte-at-a-time, and the gzip footer check was the hottest code in
/// the benchmark.
const crc_tables = blk: {
    @setEvalBranchQuota(100_000);
    var t: [8][256]u32 = undefined;
    for (0..256) |n| {
        var c: u32 = @intCast(n);
        for (0..8) |_| c = if (c & 1 != 0) 0xEDB8_8320 ^ (c >> 1) else c >> 1;
        t[0][n] = c;
    }
    for (1..8) |k| {
        for (0..256) |n| t[k][n] = t[0][t[k - 1][n] & 0xFF] ^ (t[k - 1][n] >> 8);
    }
    break :blk t;
};

fn crc32(bytes: []const u8) u32 {
    var c: u32 = 0xFFFF_FFFF;
    var i: usize = 0;
    while (i + 8 <= bytes.len) : (i += 8) {
        const lo = c ^ std.mem.readInt(u32, bytes[i..][0..4], .little);
        const hi = std.mem.readInt(u32, bytes[i + 4 ..][0..4], .little);
        c = crc_tables[7][lo & 0xFF] ^ crc_tables[6][(lo >> 8) & 0xFF] ^
            crc_tables[5][(lo >> 16) & 0xFF] ^ crc_tables[4][lo >> 24] ^
            crc_tables[3][hi & 0xFF] ^ crc_tables[2][(hi >> 8) & 0xFF] ^
            crc_tables[1][(hi >> 16) & 0xFF] ^ crc_tables[0][hi >> 24];
    }
    while (i < bytes.len) : (i += 1) c = crc_tables[0][(c ^ bytes[i]) & 0xFF] ^ (c >> 8);
    return c ^ 0xFFFF_FFFF;
}

test "crc32 matches std.hash.Crc32" {
    var buf: [1037]u8 = undefined;
    for (&buf, 0..) |*b, n| b.* = @truncate(n *% 2654435761);
    for ([_]usize{ 0, 1, 7, 8, 9, 64, 1037 }) |len| {
        try std.testing.expectEqual(std.hash.Crc32.hash(buf[0..len]), crc32(buf[0..len]));
    }
}

fn decompress(gpa: Allocator, data: []u8, compression: Compression, limit: u64, what: Limited, diag: ?*Diagnostics) Error![]u8 {
    switch (compression) {
        .none => return data,
        .gzip => {
            defer gpa.free(data);
            var in: std.Io.Reader = .fixed(data);
            var inflate: std.compress.flate.Decompress = .init(&in, .gzip, &.{});
            const out = inflate.reader.allocRemaining(gpa, .limited64(limit)) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.StreamTooLong => return switch (what) {
                    .directory => fail(diag, "directory_too_large", null, error.LimitExceeded),
                    .metadata => fail(diag, "metadata_too_large", null, error.LimitExceeded),
                },
                error.ReadFailed => return corrupt(what, diag),
            };
            // std.compress.flate reads the gzip footer but leaves checking it
            // to the caller.
            const footer = inflate.container_metadata.gzip;
            if (footer.crc != crc32(out) or footer.count != @as(u32, @truncate(out.len))) {
                gpa.free(out);
                return corrupt(what, diag);
            }
            return out;
        },
        else => {
            gpa.free(data);
            return fail(diag, "unsupported_compression", null, error.Unsupported);
        },
    }
}

fn readDirectory(gpa: Allocator, src: Source, header: pmtiles.Header, offset: u64, len: u64, opts: Options, diag: ?*Diagnostics) Error![]pmtiles.Entry {
    if (len > opts.max_directory_bytes) return fail(diag, "directory_too_large", null, error.LimitExceeded);
    const raw = try readExact(gpa, src, offset, len, diag);
    const bytes = try decompress(gpa, raw, header.internal_compression, opts.max_directory_bytes, .directory, diag);
    defer gpa.free(bytes);
    return pmtiles.decodeDirectory(gpa, bytes, opts, diag);
}

/// Spec operation `get_tile`. Returns tile z/x/y's bytes, still compressed
/// with the header's `tile_compression`, or null when the archive has no
/// such tile. Follows leaf directories up to `opts.max_leaf_depth`. The
/// caller owns the returned slice and frees it with `gpa`.
///
/// Stateless: reads the header and root directory on every call. For many
/// lookups on one archive, use `Reader`, which keeps them.
pub fn getTile(gpa: Allocator, src: Source, coord: TileCoord, opts: Options, diag: ?*Diagnostics) Error!?[]u8 {
    const header = try readHeader(gpa, src, diag);
    const tile_id = try pmtiles.zxyToTileId(coord, diag);
    const root = try readDirectory(gpa, src, header, header.root_directory_offset, header.root_directory_length, opts, diag);
    defer gpa.free(root);
    return findTile(gpa, src, header, root, tile_id, opts, diag);
}

/// An open archive: the header and decoded root directory, read once by
/// `init`, so each lookup reads only leaf directories and the tile itself.
/// Returns the same results and errors as `getTile`, except that header and
/// root directory errors come from `init`. Call `deinit` when done.
pub const Reader = struct {
    gpa: Allocator,
    src: Source,
    opts: Options,
    header: pmtiles.Header,
    root: []pmtiles.Entry,

    /// Reads the header and root directory. `gpa` holds the root until
    /// `deinit`; `src` must outlive the reader.
    pub fn init(gpa: Allocator, src: Source, opts: Options, diag: ?*Diagnostics) Error!Reader {
        const header = try readHeader(gpa, src, diag);
        const root = try readDirectory(gpa, src, header, header.root_directory_offset, header.root_directory_length, opts, diag);
        return .{ .gpa = gpa, .src = src, .opts = opts, .header = header, .root = root };
    }

    pub fn deinit(self: *Reader) void {
        self.gpa.free(self.root);
        self.* = undefined;
    }

    /// `get_tile` on the open archive. The caller owns the returned slice and
    /// frees it with `gpa`, which may differ from the reader's.
    pub fn getTile(self: *const Reader, gpa: Allocator, coord: TileCoord, diag: ?*Diagnostics) Error!?[]u8 {
        const tile_id = try pmtiles.zxyToTileId(coord, diag);
        return findTile(gpa, self.src, self.header, self.root, tile_id, self.opts, diag);
    }
};

/// Finds `tile_id` starting from the decoded root directory, following leaf
/// directories, and reads the tile.
fn findTile(gpa: Allocator, src: Source, header: pmtiles.Header, root: []const pmtiles.Entry, tile_id: u64, opts: Options, diag: ?*Diagnostics) Error!?[]u8 {
    var entries = root;
    var leaf: ?[]pmtiles.Entry = null; // the current leaf directory, owned here
    defer if (leaf) |l| gpa.free(l);
    var depth: u32 = 0; // the root is depth 0
    while (true) {
        const entry = pmtiles.findEntry(entries, tile_id) orelse return null;
        if (entry.run_length > 0) {
            const start = std.math.add(u64, header.tile_data_offset, entry.offset) catch
                return fail(diag, "invalid_directory", null, error.InvalidInput);
            return try readExact(gpa, src, start, entry.length, diag);
        }
        if (depth == opts.max_leaf_depth) return fail(diag, "leaf_depth_exceeded", null, error.LimitExceeded);
        depth += 1;
        const offset = std.math.add(u64, header.leaf_directories_offset, entry.offset) catch
            return fail(diag, "invalid_directory", null, error.InvalidInput);
        const next = try readDirectory(gpa, src, header, offset, entry.length, opts, diag);
        if (leaf) |l| gpa.free(l);
        leaf = next;
        entries = next;
    }
}

/// Spec operation `read_metadata`. Returns the archive's metadata JSON,
/// decompressed but unparsed, exactly as stored. The caller owns the
/// returned slice and frees it with `gpa`.
pub fn readMetadata(gpa: Allocator, src: Source, opts: Options, diag: ?*Diagnostics) Error![]u8 {
    const header = try readHeader(gpa, src, diag);
    if (header.metadata_length > opts.max_metadata_bytes)
        return fail(diag, "metadata_too_large", null, error.LimitExceeded);
    const raw = try readExact(gpa, src, header.metadata_offset, header.metadata_length, diag);
    return decompress(gpa, raw, header.internal_compression, opts.max_metadata_bytes, .metadata, diag);
}

// ---------------------------------------------------------------------------
// Unit tests: leaf following and its limit on hand-built archives, sources,
// and a fuzz target over mutated archives.
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Builds an uncompressed archive. `dirs[0]` is the root; leaf pointers in
/// any directory refer to `dirs[i]` by `offset` = i's byte offset within the
/// leaf section, which `buildArchive` computes from `leaf_index`.
const TestDir = []const pmtiles.Entry;

fn buildArchive(gpa: Allocator, root: TestDir, leaves: []const TestDir, tiles: []const u8, metadata: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendNTimes(gpa, 0, pmtiles.header_len);

    const root_bytes = try pmtiles.encodeDirectory(gpa, root);
    defer gpa.free(root_bytes);
    try out.appendSlice(gpa, root_bytes);
    const meta_off = out.items.len;
    try out.appendSlice(gpa, metadata);
    const leaf_off = out.items.len;
    for (leaves) |leaf| {
        const b = try pmtiles.encodeDirectory(gpa, leaf);
        defer gpa.free(b);
        try out.appendSlice(gpa, b);
    }
    const tile_off = out.items.len;
    try out.appendSlice(gpa, tiles);

    const h = out.items[0..pmtiles.header_len];
    @memcpy(h[0..7], "PMTiles");
    h[7] = 3;
    const fields = [_]u64{ 127, root_bytes.len, meta_off, metadata.len, leaf_off, tile_off - leaf_off, tile_off, tiles.len };
    for (fields, 0..) |v, i| std.mem.writeInt(u64, h[8 + 8 * i ..][0..8], v, .little);
    h[97] = @backingInt(Compression.none);
    h[98] = @backingInt(Compression.none);
    return out.toOwnedSlice(gpa);
}

/// Encoded length of `dir`, for computing leaf offsets.
fn dirLen(gpa: Allocator, dir: TestDir) !u32 {
    const b = try pmtiles.encodeDirectory(gpa, dir);
    defer gpa.free(b);
    return @intCast(b.len);
}

test "get_tile: follows a leaf directory; read_metadata returns the text as stored" {
    const gpa = testing.allocator;
    // Tiles 0..3 live in a leaf; tile 4 is in the root.
    const leaf = [_]pmtiles.Entry{
        .{ .tile_id = 0, .offset = 0, .length = 1, .run_length = 1 },
        .{ .tile_id = 1, .offset = 1, .length = 2, .run_length = 3 },
    };
    const root = [_]pmtiles.Entry{
        .{ .tile_id = 0, .offset = 0, .length = try dirLen(gpa, &leaf), .run_length = 0 },
        .{ .tile_id = 4, .offset = 3, .length = 3, .run_length = 1 },
    };
    const archive = try buildArchive(gpa, &root, &.{&leaf}, "abbccc", "{\"a\": 1}");
    defer gpa.free(archive);
    var mem: MemorySource = .init(archive);
    const src = mem.source();

    const want = [_]struct { TileCoord, ?[]const u8 }{
        .{ .{ .z = 0, .x = 0, .y = 0 }, "a" },
        .{ .{ .z = 1, .x = 0, .y = 1 }, "bb" }, // id 2, inside the run
        .{ .{ .z = 1, .x = 1, .y = 1 }, "bb" }, // id 3
        .{ .{ .z = 1, .x = 1, .y = 0 }, "ccc" }, // id 4, root
        .{ .{ .z = 2, .x = 0, .y = 0 }, null }, // id 5, past everything
    };
    var reader: Reader = try .init(gpa, src, .{}, null);
    defer reader.deinit();
    for (want) |w| {
        const got = try getTile(gpa, src, w[0], .{}, null);
        defer if (got) |g| gpa.free(g);
        if (w[1]) |bytes| try testing.expectEqualStrings(bytes, got.?) else try testing.expectEqual(@as(?[]u8, null), got);
        // The caching reader returns the same bytes.
        const cached = try reader.getTile(gpa, w[0], null);
        defer if (cached) |g| gpa.free(g);
        if (w[1]) |bytes| try testing.expectEqualStrings(bytes, cached.?) else try testing.expectEqual(@as(?[]u8, null), cached);
    }
    const meta = try readMetadata(gpa, src, .{}, null);
    defer gpa.free(meta);
    try testing.expectEqualStrings("{\"a\": 1}", meta);
}

test "get_tile: leaf depth is bounded (D-005)" {
    const gpa = testing.allocator;
    // A chain root -> leaf 0 -> leaf 1 -> ... -> leaf 4 -> tile: 5 leaf pointers.
    const tile = [_]pmtiles.Entry{.{ .tile_id = 0, .offset = 0, .length = 1, .run_length = 1 }};
    const tile_len = try dirLen(gpa, &tile);
    var chain: [5][1]pmtiles.Entry = undefined;
    var dirs: [5]TestDir = undefined;
    // Leaves are laid out in order; each pointer's length is that of the next
    // pointer directory (all pointer directories encode to the same length).
    const ptr_len = blk: {
        const probe = [_]pmtiles.Entry{.{ .tile_id = 0, .offset = 0, .length = tile_len, .run_length = 0 }};
        break :blk try dirLen(gpa, &probe);
    };
    for (0..4) |i| {
        chain[i] = .{.{ .tile_id = 0, .offset = (i + 1) * ptr_len, .length = ptr_len, .run_length = 0 }};
        dirs[i] = &chain[i];
    }
    chain[3][0].length = tile_len;
    dirs[4] = &tile;
    // Pointer directories with explicit offset 1..4 * ptr_len all encode to
    // ptr_len bytes only while the offsets fit in one varint byte.
    for (dirs[0..4]) |d| try testing.expectEqual(ptr_len, try dirLen(gpa, d));
    const root = [_]pmtiles.Entry{.{ .tile_id = 0, .offset = 0, .length = ptr_len, .run_length = 0 }};
    const archive = try buildArchive(gpa, &root, &dirs, "t", "{}");
    defer gpa.free(archive);
    var mem: MemorySource = .init(archive);

    // root (depth 0) -> 5 leaf pointers -> tile. Allowed at max_leaf_depth 5.
    const got = (try getTile(gpa, mem.source(), .{ .z = 0, .x = 0, .y = 0 }, .{ .max_leaf_depth = 5 }, null)).?;
    defer gpa.free(got);
    try testing.expectEqualStrings("t", got);
    // The default (4) stops at the fifth pointer.
    var diag: Diagnostics = .{};
    try testing.expectError(error.LimitExceeded, getTile(gpa, mem.source(), .{ .z = 0, .x = 0, .y = 0 }, .{}, &diag));
    try testing.expectEqualStrings("pmtiles.leaf_depth_exceeded", diag.code);
}

/// A source whose every read fails.
const Broken = struct {
    fn source(self: *Broken) Source {
        return .{ .ptr = self, .vtable = &.{ .readRange = readRange } };
    }
    fn readRange(_: *anyopaque, _: Allocator, _: u64, _: u64) Source.ReadError![]u8 {
        return error.ReadFailed;
    }
};

test "get_tile: limits and source errors" {
    const gpa = testing.allocator;
    const root = [_]pmtiles.Entry{.{ .tile_id = 0, .offset = 0, .length = 100, .run_length = 1 }};
    const archive = try buildArchive(gpa, &root, &.{}, "short", "{}");
    defer gpa.free(archive);
    var mem: MemorySource = .init(archive);
    var diag: Diagnostics = .{};

    // The tile runs past the end of the source.
    try testing.expectError(error.InvalidInput, getTile(gpa, mem.source(), .{ .z = 0, .x = 0, .y = 0 }, .{}, &diag));
    try testing.expectEqualStrings("pmtiles.truncated", diag.code);
    // A source that fails is source_failed.
    var broken: Broken = .{};
    try testing.expectError(error.Io, readMetadata(gpa, broken.source(), .{}, &diag));
    try testing.expectEqualStrings("pmtiles.source_failed", diag.code);
    // Root directory longer than allowed: rejected before it is read.
    try testing.expectError(error.LimitExceeded, getTile(gpa, mem.source(), .{ .z = 0, .x = 0, .y = 0 }, .{ .max_directory_bytes = 2 }, &diag));
    try testing.expectEqualStrings("pmtiles.directory_too_large", diag.code);
    try testing.expectError(error.LimitExceeded, readMetadata(gpa, mem.source(), .{ .max_metadata_bytes = 1 }, &diag));
    try testing.expectEqualStrings("pmtiles.metadata_too_large", diag.code);
    // Coordinate errors come after the header and before any directory read.
    try testing.expectError(error.InvalidInput, getTile(gpa, mem.source(), .{ .z = 1, .x = 2, .y = 0 }, .{}, &diag));
    try testing.expectEqualStrings("pmtiles.tile_out_of_range", diag.code);
    // A source shorter than the header is truncated, as for decode_header.
    var short: MemorySource = .init(archive[0..50]);
    try testing.expectError(error.InvalidInput, getTile(gpa, short.source(), .{ .z = 0, .x = 0, .y = 0 }, .{}, &diag));
    try testing.expectEqualStrings("pmtiles.truncated", diag.code);
}

test "get_tile: gzip directories; decompression limits and failures" {
    const gpa = testing.allocator;
    const small = @embedFile("small.pmtiles");
    var mem: MemorySource = .init(small);
    const got = (try getTile(gpa, mem.source(), .{ .z = 2, .x = 1, .y = 3 }, .{}, null)).?;
    defer gpa.free(got);
    try testing.expectEqualStrings("b.b.b.", got);

    // Output is bounded too: 29 bytes of gzip inflate to 1000 zero bytes.
    const zeros = "\x1f\x8b\x08\x00\x00\x00\x00\x00\x02\xff\x63\x60\x18\x05\xa3\x60\x14\x0c\x77\x00\x00\x80\x17\x0b\x06\xe8\x03\x00\x00";
    const out = try decompress(gpa, try gpa.dupe(u8, zeros), .gzip, 1000, .directory, null);
    defer gpa.free(out);
    try testing.expectEqual(@as(usize, 1000), out.len);
    var diag: Diagnostics = .{};
    try testing.expectError(error.LimitExceeded, decompress(gpa, try gpa.dupe(u8, zeros), .gzip, 999, .metadata, &diag));
    try testing.expectEqualStrings("pmtiles.metadata_too_large", diag.code);
    // A corrupt stream (bad CRC, or cut off) is invalid input.
    var bad = zeros.*;
    bad[bad.len - 6] ^= 1;
    try testing.expectError(error.InvalidInput, decompress(gpa, try gpa.dupe(u8, &bad), .gzip, 1000, .directory, &diag));
    try testing.expectEqualStrings("pmtiles.invalid_directory", diag.code);
    try testing.expectError(error.InvalidInput, decompress(gpa, try gpa.dupe(u8, zeros[0..20]), .gzip, 1000, .metadata, &diag));
    try testing.expectEqualStrings("pmtiles.truncated", diag.code);
    try testing.expectError(error.Unsupported, decompress(gpa, try gpa.dupe(u8, zeros), .brotli, 1000, .directory, &diag));
    try testing.expectEqualStrings("pmtiles.unsupported_compression", diag.code);
}

test "FileSource reads the same bytes as MemorySource" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const small = @embedFile("small.pmtiles");
    try tmp.dir.writeFile(io, .{ .sub_path = "small.pmtiles", .data = small });

    var file: FileSource = try .open(io, tmp.dir, "small.pmtiles");
    defer file.close();
    var mem: MemorySource = .init(small);
    for ([_]TileCoord{ .{ .z = 0, .x = 0, .y = 0 }, .{ .z = 3, .x = 0, .y = 1 }, .{ .z = 3, .x = 7, .y = 7 } }) |c| {
        const a = try getTile(gpa, file.source(), c, .{}, null);
        defer if (a) |s| gpa.free(s);
        const b = try getTile(gpa, mem.source(), c, .{}, null);
        defer if (b) |s| gpa.free(s);
        try testing.expectEqual(a == null, b == null);
        if (a) |s| try testing.expectEqualStrings(b.?, s);
    }
    const tail = try file.source().readRange(gpa, small.len - 3, 10);
    defer gpa.free(tail);
    try testing.expectEqual(@as(usize, 3), tail.len);
}

test "fuzz: get_tile, Reader and read_metadata on mutated archives return only declared errors" {
    try testing.fuzz({}, fuzzArchive, .{});
}

fn fuzzArchive(context: void, smith: *testing.Smith) !void {
    _ = context;
    const archives = [_][]const u8{ @embedFile("small.pmtiles"), @embedFile("small-uncompressed.pmtiles") };
    const base = archives[smith.index(archives.len)];
    var buf: [2048]u8 = undefined;
    std.debug.assert(base.len <= buf.len);
    @memcpy(buf[0..base.len], base);
    var len = base.len;
    // A few byte mutations, weighted toward the header and the directories.
    const mutations = smith.valueRangeAtMost(u8, 0, 8);
    for (0..mutations) |_| {
        const at = if (smith.boolWeighted(1, 1)) smith.index(@min(len, 600)) else smith.index(len);
        buf[at] = smith.value(u8);
    }
    if (smith.boolWeighted(7, 1)) len = smith.valueRangeAtMost(u16, 0, @intCast(len));
    const coord: TileCoord = .{
        .z = smith.valueRangeAtMost(u8, 0, 33),
        .x = smith.valueRangeAtMost(u32, 0, 9),
        .y = smith.valueRangeAtMost(u32, 0, 9),
    };
    const opts: Options = .{ .max_leaf_depth = smith.valueRangeAtMost(u32, 0, 4) };

    const gpa = testing.allocator;
    var mem: MemorySource = .init(buf[0..len]);
    var diag: Diagnostics = .{};
    const direct = getTile(gpa, mem.source(), coord, opts, &diag);
    defer if (direct) |tile| if (tile) |t| gpa.free(t) else {} else |_| {};
    if (direct) |_| {} else |err| try expectCoded(err, diag);

    // The caching reader agrees with getTile: same bytes, or the same error.
    diag = .{};
    if (Reader.init(gpa, mem.source(), opts, &diag)) |r| {
        var reader = r;
        defer reader.deinit();
        diag = .{};
        if (reader.getTile(gpa, coord, &diag)) |tile| {
            defer if (tile) |t| gpa.free(t);
            const want = direct catch return error.TestUnexpectedResult;
            if (want) |w| try testing.expectEqualSlices(u8, w, tile.?) else try testing.expectEqual(@as(?[]u8, null), tile);
        } else |err| {
            try expectCoded(err, diag);
            try testing.expectError(err, direct);
        }
    } else |err| {
        try expectCoded(err, diag);
        try testing.expectError(err, direct);
    }
    diag = .{};
    if (readMetadata(gpa, mem.source(), opts, &diag)) |meta| {
        gpa.free(meta);
    } else |err| try expectCoded(err, diag);
}

fn expectCoded(err: Error, diag: Diagnostics) !void {
    switch (err) {
        error.InvalidInput, error.Unsupported, error.LimitExceeded, error.Io => try testing.expect(diag.code.len > 0),
        error.OutOfMemory => return error.TestUnexpectedResult,
    }
}
