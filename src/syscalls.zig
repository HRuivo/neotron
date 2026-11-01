const std = @import("std");
const syscall = @import("syscall");
const console = @import("console.zig");
const process = @import("process.zig");

pub fn handleSyscall(number: usize, arg0: usize) usize {
    switch (number) {
        @backingInt(syscall.Number.putchar) => {
            console.putChar(@truncate(arg0)) catch @panic("console write failed");
            return arg0;
        },
        @backingInt(syscall.Number.getchar) => {
            while (true) {
                if (console.getChar()) |ch| {
                    return ch;
                }

                process.yield();
            }
        },
        @backingInt(syscall.Number.exit) => {
            console.print("process {d} exited\n", .{process.currentPid()}) catch {};
            process.exitCurrent();
        },
        else => std.debug.panic("unexpected syscall a3={x}", .{number}),
    }
}
