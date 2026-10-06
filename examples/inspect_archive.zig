//! Canonical example `inspect_archive`: read the first 127 bytes of a local
//! archive, decode the header, and print the zooms, bounds and tile type.
//!
//! Usage: `inspect_archive [path]` (default: the spec's small test archive).
const std = @import("std");
const pmtiles = @import("pmtiles");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const path = if (args.len > 1) args[1] else ".spec/conformance/cases/archives/small.pmtiles";

    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var buf: [pmtiles.header_len]u8 = undefined;
    const n = try file.readPositionalAll(io, &buf, 0);

    var diag: pmtiles.Diagnostics = .{};
    const h = pmtiles.decodeHeader(buf[0..n], &diag) catch |err| {
        std.debug.print("{s}: {s}\n", .{ @errorName(err), diag.code });
        return err;
    };
    const tile_type = std.enums.tagName(pmtiles.TileType, h.tile_type) orelse "unknown";
    std.debug.print("{s}\n  zooms {d}-{d}\n  bounds lon {d}..{d}, lat {d}..{d}\n  tile type {s}\n", .{
        path,
        h.min_zoom,
        h.max_zoom,
        h.bounds.min_lon,
        h.bounds.max_lon,
        h.bounds.min_lat,
        h.bounds.max_lat,
        tile_type,
    });
}
