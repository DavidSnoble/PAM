const std = @import("std");
const PAM = @import("PAM");

pub fn main() !void {
    try PAM.server();
}
