//! Benchmark: `get_tile` for every coordinate in `coords.txt` against
//! `bench.pmtiles` loaded into a `MemorySource`. 3 warm-up passes, then 15
//! timed passes; reports median and min ms per pass, and the checksum (total
//! bytes of all tiles returned), which every port must reproduce.
//!
//! Usage: `zig build bench [-- <dir>]`, where `<dir>` holds both files
//! (default `.spec/bench`). Always built ReleaseFast.

const std = @import("std");
const Io = std.Io;
const pmtiles = @import("pmtiles");
const pmtiles_io = @import("pmtiles_io");

const warmup = 3;
const runs = 15;

fn elapsedMs(io: Io, start: Io.Timestamp) f64 {
    const ns = start.durationTo(Io.Timestamp.now(io, .awake)).nanoseconds;
    return @as(f64, @floatFromInt(ns)) / 1e6;
}

/// One pass: every coordinate once. Returns the checksum.
fn pass(gpa: std.mem.Allocator, src: pmtiles_io.Source, coords: []const pmtiles.TileCoord) !u64 {
    var sum: u64 = 0;
    for (coords) |c| {
        const tile = try pmtiles_io.getTile(gpa, src, c, .{}, null) orelse continue;
        sum += tile.len;
        gpa.free(tile);
    }
    return sum;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const dir_path = if (args.len > 1) args[1] else ".spec/bench";
    var dir = try Io.Dir.cwd().openDir(io, dir_path, .{});
    defer dir.close(io);

    const archive = try dir.readFileAlloc(io, "bench.pmtiles", arena, .limited(256 * 1024 * 1024));
    const coords_text = try dir.readFileAlloc(io, "coords.txt", arena, .limited(16 * 1024 * 1024));
    var coords: std.ArrayList(pmtiles.TileCoord) = .empty;
    var lines = std.mem.tokenizeScalar(u8, coords_text, '\n');
    while (lines.next()) |line| {
        var parts = std.mem.splitScalar(u8, std.mem.trim(u8, line, " \r"), '/');
        try coords.append(arena, .{
            .z = try std.fmt.parseInt(u8, parts.next() orelse return error.BadCoord, 10),
            .x = try std.fmt.parseInt(u32, parts.next() orelse return error.BadCoord, 10),
            .y = try std.fmt.parseInt(u32, parts.next() orelse return error.BadCoord, 10),
        });
    }

    var mem: pmtiles_io.MemorySource = .init(archive);
    const src = mem.source();

    var samples: [runs]f64 = undefined;
    var checksum: ?u64 = null;
    for (0..warmup + runs) |i| {
        const start = Io.Timestamp.now(io, .awake);
        const sum = try pass(gpa, src, coords.items);
        const ms = elapsedMs(io, start);
        if (checksum != null and checksum.? != sum) return error.ChecksumChanged;
        checksum = sum;
        if (i >= warmup) samples[i - warmup] = ms;
    }
    std.mem.sort(f64, &samples, {}, std.sort.asc(f64));
    std.debug.print("pmtiles zig ReleaseFast: get_tile x {d} from memory: median {d:.3} ms (min {d:.3}) per pass, checksum {d}\n", .{
        coords.items.len,
        samples[runs / 2],
        samples[0],
        checksum.?,
    });
}
