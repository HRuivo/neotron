const std = @import("std");
const syscall = @import("syscall");
const console = @import("console/console.zig");
const process = @import("process.zig");
const programs = @import("programs.zig");
const memory = @import("memory.zig");

pub fn handleSyscall(number: usize, arg0: usize) usize {
    switch (number) {
        @backingInt(syscall.Number.putchar) => {
            defer console.flush();

            console.putChar(@truncate(arg0)) catch
                @panic("console write failed");

            return arg0;
        },
        @backingInt(syscall.Number.getchar) => {
            // Make pending output visible before waiting for input
            console.flush();

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
        @backingInt(syscall.Number.spawn) => {
            // PID 0 is reserved for idle, so use it to signal an unknown program.
            const image = programs.lookup(arg0) orelse return 0;
            const child = process.createProcess(memory.allocator(), image);
            return child.pid;
        },
        else => std.debug.panic("unexpected syscall a3={x}", .{number}),
    }
}
