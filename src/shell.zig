const user = @import("user.zig");

comptime {
    _ = user;
}

export fn main() void {
    // test user access to kernel memory
    // const kernel_memory: *volatile u32 = @ptrFromInt(0x8020_0000);
    // kernel_memory.* = 0x1234;

    const message: []const u8 = "Hello World from shell!\n";
    for (message) |c| {
        user.putChar(c);
    }

    while (true) {}
}
