const std = @import("std");
const PAM = @import("PAM");

pub fn main() !void {
    // var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    // defer _ = gpa.deinit();
    // const allocator = gpa.allocator();

    // const response = try PAM.send_llm_request();
    // defer allocator.free(response);

    // std.debug.print("Received response: {s}\n", .{response});

    try PAM.server();
}
