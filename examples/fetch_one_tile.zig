//! Canonical example `fetch_one_tile`: open a local archive as a source,
//! fetch one tile by z/x/y, and print its byte count or "not found".
//!
//! Usage: `fetch_one_tile [path [z/x/y]]` (default: the spec's small test
//! archive, tile 2/1/3).
const std = @import("std");
const pmtiles = @import("pmtiles");
const pmtiles_io = @import("pmtiles_io");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const path = if (args.len > 1) args[1] else ".spec/conformance/cases/archives/small.pmtiles";
    const zxy = if (args.len > 2) args[2] else "2/1/3";

    var parts = std.mem.splitScalar(u8, zxy, '/');
    const coord: pmtiles.TileCoord = .{
        .z = try std.fmt.parseInt(u8, parts.next().?, 10),
        .x = try std.fmt.parseInt(u32, parts.next() orelse return error.BadCoord, 10),
        .y = try std.fmt.parseInt(u32, parts.next() orelse return error.BadCoord, 10),
    };

    var file: pmtiles_io.FileSource = try .open(io, std.Io.Dir.cwd(), path);
    defer file.close();

    var diag: pmtiles.Diagnostics = .{};
    const tile = pmtiles_io.getTile(gpa, file.source(), coord, .{}, &diag) catch |err| {
        std.debug.print("{s}: {s}\n", .{ @errorName(err), diag.code });
        return err;
    };
    if (tile) |bytes| {
        defer gpa.free(bytes);
        std.debug.print("tile {s}: {d} bytes\n", .{ zxy, bytes.len });
    } else {
        std.debug.print("tile {s}: not found\n", .{zxy});
    }
}
