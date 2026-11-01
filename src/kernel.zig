const std = @import("std");

const console = @import("console.zig");
const trap = @import("arch/riscv32/trap.zig");
const memory = @import("memory.zig");
const process = @import("process.zig");
const gpu = @import("drivers/gpu.zig");
const disk = @import("drivers/disk.zig");

const bss = @extern([*]u8, .{ .name = "__bss" });
const bss_end = @extern([*]u8, .{ .name = "__bss_end" });
const stack_top = @extern([*]align(16) u8, .{ .name = "__stack_top" });

pub const panic = std.debug.FullPanic(kernelPanic);

const shell_image = @embedFile("shell_image");

fn kernelPanic(message: []const u8, return_address: ?usize) noreturn {
    _ = console.writeBytes("\nKERNEL PANIC: ") catch 0;
    _ = console.writeBytes(message) catch 0;
    const address = return_address orelse @returnAddress();
    const call_site = if (address > 0) address - 1 else address;
    console.print(" at 0x{x}\n", .{call_site}) catch {};

    while (true) asm volatile ("wfi");
}

export fn boot() linksection(".text.boot") callconv(.naked) void {
    asm volatile (
        \\mv sp, %[stack]
        \\j kernelMain
        :
        : [stack] "r" (stack_top),
    );
}

fn delay() void {
    for (0..30000000) |_| {
        asm volatile ("nop");
    }
}

export fn kernelMain() noreturn {
    const bss_len = bss_end - bss;
    @memset(bss[0..bss_len], 0);

    trap.init();

    memory.init();
    const allocator = memory.allocator();

    // Disk
    disk.init(allocator);
    var buffer: [512]u8 = undefined;
    disk.readWriteDisk(&buffer, 0, false);
    console.print("first sector: {s}\n", .{buffer[0..]}) catch {};

    // Display
    gpu.init(allocator);

    @memset(buffer[0..], 0);
    const message = "hello from kernel!!!\n";
    @memcpy(buffer[0..message.len], message);
    disk.readWriteDisk(&buffer, 0, true);

    process.init(allocator);
    _ = process.createProcess(allocator, shell_image);

    process.yield();
    @panic("switched to idle process");
}
