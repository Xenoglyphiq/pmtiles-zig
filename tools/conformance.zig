//! Conformance runner: loads `.spec/conformance/manifest.json`, runs every
//! case, converts the result to canonical JSON and compares it the way the
//! case says to (`exact`, `float_tol`, `json_equal` or `bytes`).
//!
//! io cases run twice, against a `FileSource` and a `MemorySource` over the
//! same archive, and must agree.
//!
//! Usage: `zig build conformance` (or `conformance <manifest.json>`).
//! Exit code 0 only if every case passes.

const std = @import("std");
const Io = std.Io;
const json = std.json;
const Allocator = std.mem.Allocator;
const pmtiles = @import("pmtiles");
const pmtiles_io = @import("pmtiles_io");

const Outcome = enum { pass, fail };

/// Everything a case needs besides its JSON.
const Ctx = struct {
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    /// Directory holding the case files (`<manifest dir>/cases`).
    cases_dir: Io.Dir,
    why: *std.ArrayList(u8),

    fn failf(ctx: Ctx, comptime fmt: []const u8, args: anytype) !Outcome {
        try ctx.why.print(ctx.arena, fmt, args);
        return .fail;
    }
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(arena);
    // The last argument wins, so `zig build conformance -- <manifest>` overrides
    // the vendored manifest the build step passes first.
    const manifest_path = if (args.len > 1) args[args.len - 1] else ".spec/conformance/manifest.json";
    const bytes = try Io.Dir.cwd().readFileAlloc(io, manifest_path, arena, .limited(64 * 1024 * 1024));
    const manifest = (try json.parseFromSliceLeaky(json.Value, arena, bytes, .{})).object;
    const spec_version = manifest.get("spec_version").?.string;

    const manifest_dir = std.fs.path.dirname(manifest_path) orelse ".";
    var cases_dir = try Io.Dir.cwd().openDir(io, try std.fs.path.join(arena, &.{ manifest_dir, "cases" }), .{});
    defer cases_dir.close(io);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout_writer.interface;

    var passed = [2]usize{ 0, 0 }; // core, io
    var total = [2]usize{ 0, 0 };
    for (manifest.get("cases").?.array.items) |case_value| {
        const case = case_value.object;
        const level: usize = if (std.mem.eql(u8, case.get("level").?.string, "io")) 1 else 0;
        total[level] += 1;
        var why: std.ArrayList(u8) = .empty;
        const ctx: Ctx = .{ .gpa = init.gpa, .arena = arena, .io = io, .cases_dir = cases_dir, .why = &why };
        const outcome = runCase(ctx, case) catch |err| blk: {
            try why.print(arena, "runner error: {s}", .{@errorName(err)});
            break :blk .fail;
        };
        switch (outcome) {
            .pass => passed[level] += 1,
            .fail => try out.print("FAIL {s}: {s}\n", .{ case.get("id").?.string, why.items }),
        }
    }
    try out.print("pmtiles zig (spec {s}): core {d}/{d}, io {d}/{d}, full {d}/{d}\n", .{
        spec_version,
        passed[0],
        total[0],
        passed[1],
        total[1],
        passed[0] + passed[1],
        total[0] + total[1],
    });
    try out.flush();
    if (passed[0] != total[0] or passed[1] != total[1]) std.process.exit(1);
}

// ---------------------------------------------------------------------------
// Running one case
// ---------------------------------------------------------------------------

/// The result of an operation, as canonical JSON (`{"value": …}`,
/// `{"base64": …}` or `{"error": …}`).
const Result = json.Value;

fn runCase(ctx: Ctx, case: json.ObjectMap) !Outcome {
    const op = case.get("op").?.string;
    const input = case.get("input").?.object;
    const opts = try options(case.get("options"));

    const result: Result = if (std.mem.eql(u8, op, "decode_header")) blk: {
        const bytes = try inputBytes(ctx, input);
        var diag: pmtiles.Diagnostics = .{};
        const h = pmtiles.decodeHeader(bytes, &diag) catch |err| break :blk try errorJson(ctx, err, diag);
        break :blk try valueJson(ctx, try headerJson(ctx, h));
    } else if (std.mem.eql(u8, op, "decode_directory")) blk: {
        const bytes = try inputBytes(ctx, input);
        var diag: pmtiles.Diagnostics = .{};
        const entries = pmtiles.decodeDirectory(ctx.gpa, bytes, opts, &diag) catch |err| break :blk try errorJson(ctx, err, diag);
        defer ctx.gpa.free(entries);
        var list = json.Array.init(ctx.arena);
        for (entries) |e| try list.append(try entryJson(ctx, e));
        break :blk try valueJson(ctx, .{ .array = list });
    } else if (std.mem.eql(u8, op, "zxy_to_tile_id")) blk: {
        const coord = try toCoord(input.get("value").?);
        var diag: pmtiles.Diagnostics = .{};
        const id = pmtiles.zxyToTileId(coord, &diag) catch |err| break :blk try errorJson(ctx, err, diag);
        break :blk try valueJson(ctx, try u64Json(ctx, id));
    } else if (std.mem.eql(u8, op, "tile_id_to_zxy")) blk: {
        const id = try toU64(input.get("value").?);
        var diag: pmtiles.Diagnostics = .{};
        const c = pmtiles.tileIdToZxy(id, &diag) catch |err| break :blk try errorJson(ctx, err, diag);
        break :blk try valueJson(ctx, try coordJson(ctx, c));
    } else if (std.mem.eql(u8, op, "find_entry")) blk: {
        const v = input.get("value").?.object;
        const items = v.get("entries").?.array.items;
        const entries = try ctx.arena.alloc(pmtiles.Entry, items.len);
        for (items, entries) |item, *e| e.* = try toEntry(item);
        const found = pmtiles.findEntry(entries, try toU64(v.get("tile_id").?));
        break :blk try valueJson(ctx, if (found) |e| try entryJson(ctx, e) else .null);
    } else if (std.mem.eql(u8, op, "get_tile") or std.mem.eql(u8, op, "read_metadata")) blk: {
        // Same archive through both sources; the results must agree.
        const path = input.get("file").?.string;
        var file = try pmtiles_io.FileSource.open(ctx.io, ctx.cases_dir, path);
        defer file.close();
        const from_file = try runIo(ctx, op, input, file.source(), opts);
        var mem: pmtiles_io.MemorySource = .init(try inputBytes(ctx, input));
        const from_mem = try runIo(ctx, op, input, mem.source(), opts);
        if (!jsonEqual(from_file, from_mem, 0))
            return ctx.failf("FileSource gave {s}, MemorySource gave {s}", .{ try show(ctx, from_file), try show(ctx, from_mem) });
        break :blk from_file;
    } else return ctx.failf("unknown op {s}", .{op});

    return compare(ctx, case, result);
}

fn runIo(ctx: Ctx, op: []const u8, input: json.ObjectMap, src: pmtiles_io.Source, opts: pmtiles.Options) !Result {
    var diag: pmtiles.Diagnostics = .{};
    if (std.mem.eql(u8, op, "get_tile")) {
        const coord = try toCoord(input.get("args").?.object.get("coord").?);
        const tile = pmtiles_io.getTile(ctx.gpa, src, coord, opts, &diag) catch |err| return errorJson(ctx, err, diag);
        const bytes = tile orelse return valueJson(ctx, .null);
        defer ctx.gpa.free(bytes);
        return base64Json(ctx, bytes);
    }
    const text = pmtiles_io.readMetadata(ctx.gpa, src, opts, &diag) catch |err| return errorJson(ctx, err, diag);
    defer ctx.gpa.free(text);
    return valueJson(ctx, .{ .string = try ctx.arena.dupe(u8, text) });
}

/// Compares `got` with the case's `expect`, per its `compare` mode.
fn compare(ctx: Ctx, case: json.ObjectMap, got: Result) !Outcome {
    const mode = case.get("compare").?.string;
    const expect = case.get("expect").?;
    const tol: f64 = if (std.mem.eql(u8, mode, "float_tol"))
        try toFloat(case.get("tolerance") orelse return ctx.failf("float_tol without a tolerance", .{}))
    else if (std.mem.eql(u8, mode, "exact") or std.mem.eql(u8, mode, "json_equal") or std.mem.eql(u8, mode, "bytes"))
        0
    else
        return ctx.failf("unknown compare mode {s}", .{mode});

    // Errors compare kind and code, and offset only where the case gives one.
    if (expect.object.get("error")) |want_err| {
        if (got.object.get("error")) |got_err| {
            const w = want_err.object;
            const g = got_err.object;
            const same = std.mem.eql(u8, w.get("kind").?.string, g.get("kind").?.string) and
                std.mem.eql(u8, w.get("code").?.string, g.get("code").?.string) and
                (w.get("offset") == null or (g.get("offset") != null and jsonEqual(w.get("offset").?, g.get("offset").?, 0)));
            if (same) return .pass;
        }
    } else if (jsonEqual(expect, got, tol)) return .pass;
    return ctx.failf("expected {s}, got {s}", .{ try show(ctx, expect), try show(ctx, got) });
}

// ---------------------------------------------------------------------------
// Inputs
// ---------------------------------------------------------------------------

fn options(value: ?json.Value) !pmtiles.Options {
    var opts: pmtiles.Options = .{};
    const obj = (value orelse return opts).object;
    if (obj.get("max_directory_entries")) |v| opts.max_directory_entries = try toU64(v);
    if (obj.get("max_directory_bytes")) |v| opts.max_directory_bytes = try toU64(v);
    if (obj.get("max_leaf_depth")) |v| opts.max_leaf_depth = std.math.cast(u32, try toU64(v)) orelse return error.BadOption;
    if (obj.get("max_metadata_bytes")) |v| opts.max_metadata_bytes = try toU64(v);
    return opts;
}

/// `{"file": …}` (relative to the cases directory) or `{"base64": …}`.
fn inputBytes(ctx: Ctx, input: json.ObjectMap) ![]const u8 {
    if (input.get("file")) |f| return ctx.cases_dir.readFileAlloc(ctx.io, f.string, ctx.arena, .limited(64 * 1024 * 1024));
    if (input.get("base64")) |b| return decodeBase64(ctx.arena, b.string);
    return error.BadInput;
}

fn decodeBase64(arena: Allocator, text: []const u8) ![]u8 {
    const d = std.base64.standard.Decoder;
    const out = try arena.alloc(u8, try d.calcSizeForSlice(text));
    try d.decode(out, text);
    return out;
}

/// Canonical u64: a number, or a decimal string beyond 2^53.
fn toU64(v: json.Value) !u64 {
    return switch (v) {
        .integer => |i| std.math.cast(u64, i) orelse error.BadInteger,
        .number_string, .string => |s| try std.fmt.parseInt(u64, s, 10),
        else => error.BadInteger,
    };
}

fn toFloat(v: json.Value) !f64 {
    return switch (v) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        .number_string => |s| try std.fmt.parseFloat(f64, s),
        .string => |s| if (std.mem.eql(u8, s, "NaN"))
            std.math.nan(f64)
        else if (std.mem.eql(u8, s, "Infinity"))
            std.math.inf(f64)
        else if (std.mem.eql(u8, s, "-Infinity"))
            -std.math.inf(f64)
        else
            error.BadFloat,
        else => error.BadFloat,
    };
}

fn toCoord(v: json.Value) !pmtiles.TileCoord {
    const o = v.object;
    return .{
        .z = std.math.cast(u8, try toU64(o.get("z").?)) orelse return error.BadCoord,
        .x = std.math.cast(u32, try toU64(o.get("x").?)) orelse return error.BadCoord,
        .y = std.math.cast(u32, try toU64(o.get("y").?)) orelse return error.BadCoord,
    };
}

fn toEntry(v: json.Value) !pmtiles.Entry {
    const o = v.object;
    return .{
        .tile_id = try toU64(o.get("tile_id").?),
        .offset = try toU64(o.get("offset").?),
        .length = std.math.cast(u32, try toU64(o.get("length").?)) orelse return error.BadEntry,
        .run_length = std.math.cast(u32, try toU64(o.get("run_length").?)) orelse return error.BadEntry,
    };
}

// ---------------------------------------------------------------------------
// Canonical JSON (.kit/CONVENTIONS.md §5)
// ---------------------------------------------------------------------------

fn object(ctx: Ctx, fields: anytype) !json.Value {
    var map: json.ObjectMap = .empty;
    inline for (fields) |f| try map.put(ctx.arena, f[0], f[1]);
    return .{ .object = map };
}

fn valueJson(ctx: Ctx, v: json.Value) !Result {
    return object(ctx, .{.{ "value", v }});
}

fn base64Json(ctx: Ctx, bytes: []const u8) !Result {
    const e = std.base64.standard.Encoder;
    const text = try ctx.arena.alloc(u8, e.calcSize(bytes.len));
    _ = e.encode(text, bytes);
    return object(ctx, .{.{ "base64", json.Value{ .string = text } }});
}

fn kindOf(err: pmtiles.Error) []const u8 {
    return switch (err) {
        error.InvalidInput => "invalid_input",
        error.Unsupported => "unsupported",
        error.LimitExceeded => "limit_exceeded",
        error.Io => "io",
        error.OutOfMemory => "out_of_memory",
    };
}

fn errorJson(ctx: Ctx, err: pmtiles.Error, diag: pmtiles.Diagnostics) !Result {
    const body = if (diag.offset) |off|
        try object(ctx, .{ .{ "kind", json.Value{ .string = kindOf(err) } }, .{ "code", json.Value{ .string = diag.code } }, .{ "offset", try u64Json(ctx, off) } })
    else
        try object(ctx, .{ .{ "kind", json.Value{ .string = kindOf(err) } }, .{ "code", json.Value{ .string = diag.code } } });
    return object(ctx, .{.{ "error", body }});
}

/// Integers within 2^53 are numbers; beyond, decimal strings.
fn u64Json(ctx: Ctx, v: u64) !json.Value {
    if (v <= (1 << 53)) return .{ .integer = @intCast(v) };
    return .{ .string = try std.fmt.allocPrint(ctx.arena, "{d}", .{v}) };
}

fn enumJson(ctx: Ctx, comptime E: type, v: E) !json.Value {
    if (std.enums.tagName(E, v)) |name| return .{ .string = name };
    return object(ctx, .{.{ "unknown", json.Value{ .integer = @backingInt(v) } }});
}

fn optJson(ctx: Ctx, v: ?u64) !json.Value {
    return if (v) |n| u64Json(ctx, n) else .null;
}

fn headerJson(ctx: Ctx, h: pmtiles.Header) !json.Value {
    return object(ctx, .{
        .{ "spec_version", json.Value{ .integer = h.spec_version } },
        .{ "root_directory_offset", try u64Json(ctx, h.root_directory_offset) },
        .{ "root_directory_length", try u64Json(ctx, h.root_directory_length) },
        .{ "metadata_offset", try u64Json(ctx, h.metadata_offset) },
        .{ "metadata_length", try u64Json(ctx, h.metadata_length) },
        .{ "leaf_directories_offset", try u64Json(ctx, h.leaf_directories_offset) },
        .{ "leaf_directories_length", try u64Json(ctx, h.leaf_directories_length) },
        .{ "tile_data_offset", try u64Json(ctx, h.tile_data_offset) },
        .{ "tile_data_length", try u64Json(ctx, h.tile_data_length) },
        .{ "addressed_tiles_count", try optJson(ctx, h.addressed_tiles_count) },
        .{ "tile_entries_count", try optJson(ctx, h.tile_entries_count) },
        .{ "tile_contents_count", try optJson(ctx, h.tile_contents_count) },
        .{ "clustered", json.Value{ .bool = h.clustered } },
        .{ "internal_compression", try enumJson(ctx, pmtiles.Compression, h.internal_compression) },
        .{ "tile_compression", try enumJson(ctx, pmtiles.Compression, h.tile_compression) },
        .{ "tile_type", try enumJson(ctx, pmtiles.TileType, h.tile_type) },
        .{ "min_zoom", json.Value{ .integer = h.min_zoom } },
        .{ "max_zoom", json.Value{ .integer = h.max_zoom } },
        .{ "bounds", try object(ctx, .{
            .{ "min_lon", json.Value{ .float = h.bounds.min_lon } },
            .{ "min_lat", json.Value{ .float = h.bounds.min_lat } },
            .{ "max_lon", json.Value{ .float = h.bounds.max_lon } },
            .{ "max_lat", json.Value{ .float = h.bounds.max_lat } },
        }) },
        .{ "center_zoom", json.Value{ .integer = h.center_zoom } },
        .{ "center", try object(ctx, .{
            .{ "lon", json.Value{ .float = h.center.lon } },
            .{ "lat", json.Value{ .float = h.center.lat } },
        }) },
    });
}

fn entryJson(ctx: Ctx, e: pmtiles.Entry) !json.Value {
    return object(ctx, .{
        .{ "tile_id", try u64Json(ctx, e.tile_id) },
        .{ "offset", try u64Json(ctx, e.offset) },
        .{ "length", json.Value{ .integer = e.length } },
        .{ "run_length", json.Value{ .integer = e.run_length } },
    });
}

fn coordJson(ctx: Ctx, c: pmtiles.TileCoord) !json.Value {
    return object(ctx, .{
        .{ "z", json.Value{ .integer = c.z } },
        .{ "x", json.Value{ .integer = c.x } },
        .{ "y", json.Value{ .integer = c.y } },
    });
}

// ---------------------------------------------------------------------------
// Comparison
// ---------------------------------------------------------------------------

fn isNumber(v: json.Value) bool {
    return v == .integer or v == .float or v == .number_string;
}

/// Structural equality: objects by key (order-insensitive), arrays in order,
/// integers exactly, and floats within `tol` (exactly when `tol` is 0).
fn jsonEqual(a: json.Value, b: json.Value, tol: f64) bool {
    if (isNumber(a) and isNumber(b)) {
        if (a == .integer and b == .integer) return a.integer == b.integer;
        const x = toFloat(a) catch return false;
        const y = toFloat(b) catch return false;
        if (std.math.isNan(x) or std.math.isNan(y)) return std.math.isNan(x) and std.math.isNan(y);
        return if (tol == 0) x == y else @abs(x - y) <= tol;
    }
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .null => true,
        .bool => |x| x == b.bool,
        .string => |x| std.mem.eql(u8, x, b.string),
        .array => |x| blk: {
            if (x.items.len != b.array.items.len) break :blk false;
            for (x.items, b.array.items) |p, q| if (!jsonEqual(p, q, tol)) break :blk false;
            break :blk true;
        },
        .object => |x| blk: {
            if (x.count() != b.object.count()) break :blk false;
            var it = x.iterator();
            while (it.next()) |kv| {
                const other = b.object.get(kv.key_ptr.*) orelse break :blk false;
                if (!jsonEqual(kv.value_ptr.*, other, tol)) break :blk false;
            }
            break :blk true;
        },
        else => false,
    };
}

fn show(ctx: Ctx, v: json.Value) ![]const u8 {
    const text = try json.Stringify.valueAlloc(ctx.arena, v, .{});
    const max = 300;
    if (text.len <= max) return text;
    return std.fmt.allocPrint(ctx.arena, "{s}… ({d} bytes)", .{ text[0..max], text.len });
}
