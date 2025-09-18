//! By convention, root.zig is the root source file when making a library.
const std = @import("std");
const zap = @import("zap");

const html_content = @embedFile("static/index.html");

pub fn server() !void {
    var listener = zap.HttpListener.init(.{
        .port = 3999,
        .on_request = on_request,
        .log = true,
    });

    try listener.listen();

    std.debug.print("Listening on 0.0.0.0:3999\n", .{});

    zap.start(.{
        .threads = 2,
        .workers = 2,
    });
}
fn on_request(r: zap.Request) !void {
    if (r.path) |the_path| {
        std.debug.print("PATH: {s}\n", .{the_path});
    }

    if (r.query) |the_query| {
        std.debug.print("QUERY: {s}\n", .{the_query});
    }
    r.sendBody(html_content) catch return;
}