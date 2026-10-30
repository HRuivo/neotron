const user = @import("user.zig");

comptime {
    _ = user;
}

export fn main() void {
    while (true) {}
}
