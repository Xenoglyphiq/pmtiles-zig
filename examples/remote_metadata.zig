//! Canonical example `remote_metadata`: read an archive's metadata over HTTP
//! range requests and print the JSON.
//!
//! `HttpSource` is a complete `Source` built on `std.http.Client`: each read
//! is one `GET` with a `Range` header. It asks for `Accept-Encoding: identity`,
//! because some servers otherwise gzip the response and apply the range to
//! the gzipped bytes. A `200` reply (range ignored) is the whole file, which
//! it slices itself; `416` means the range starts past the end.
//!
//! Usage: `remote_metadata [url]`. Needs the network.
const std = @import("std");
const pmtiles = @import("pmtiles");
const pmtiles_io = @import("pmtiles_io");

const default_url = "https://pmtiles.io/protomaps(vector)ODbL_firenze.pmtiles";

const HttpSource = struct {
    client: *std.http.Client,
    url: []const u8,

    fn source(self: *HttpSource) pmtiles_io.Source {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: pmtiles_io.Source.VTable = .{ .readRange = readRange };

    fn readRange(ptr: *anyopaque, gpa: std.mem.Allocator, offset: u64, len: u64) pmtiles_io.Source.ReadError![]u8 {
        const self: *HttpSource = @ptrCast(@alignCast(ptr));
        if (len == 0) return gpa.alloc(u8, 0);
        const n = std.math.cast(usize, len) orelse return error.ReadFailed;
        const last = std.math.add(u64, offset, len - 1) catch return error.ReadFailed;

        var range_buf: [64]u8 = undefined;
        const range = std.fmt.bufPrint(&range_buf, "bytes={d}-{d}", .{ offset, last }) catch unreachable;
        const uri = std.Uri.parse(self.url) catch return error.ReadFailed;
        var req = self.client.request(.GET, uri, .{
            .headers = .{ .accept_encoding = .{ .override = "identity" } },
            .extra_headers = &.{.{ .name = "Range", .value = range }},
            // A 200 reply may be left half-read, so don't reuse connections.
            .keep_alive = false,
        }) catch return error.ReadFailed;
        defer req.deinit();
        req.sendBodiless() catch return error.ReadFailed;
        var redirect_buf: [8 * 1024]u8 = undefined;
        var response = req.receiveHead(&redirect_buf) catch return error.ReadFailed;
        if (response.head.content_encoding != .identity) return error.ReadFailed;

        var transfer_buf: [4096]u8 = undefined;
        const body = response.reader(&transfer_buf);
        switch (response.head.status) {
            .partial_content => {},
            // The server ignored the range and sent the whole file.
            .ok => body.discardAll64(offset) catch |err| switch (err) {
                error.EndOfStream => return gpa.alloc(u8, 0),
                error.ReadFailed => return error.ReadFailed,
            },
            .range_not_satisfiable => return gpa.alloc(u8, 0),
            else => return error.ReadFailed,
        }
        const buf = try gpa.alloc(u8, n);
        errdefer gpa.free(buf);
        const got = body.readSliceShort(buf) catch return error.ReadFailed;
        return gpa.realloc(buf, got);
    }
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const url = if (args.len > 1) args[1] else default_url;

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    var http: HttpSource = .{ .client = &client, .url = url };

    var diag: pmtiles.Diagnostics = .{};
    const metadata = pmtiles_io.readMetadata(gpa, http.source(), .{}, &diag) catch |err| {
        std.debug.print("{s}: {s}\n", .{ @errorName(err), diag.code });
        return err;
    };
    defer gpa.free(metadata);
    std.debug.print("{s}\n", .{metadata});
}
