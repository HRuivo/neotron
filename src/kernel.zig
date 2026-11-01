const std = @import("std");

const console = @import("console.zig");
const trap = @import("arch/riscv32/trap.zig");
const process = @import("process.zig");
const gpu = @import("drivers/gpu.zig");
const disk = @import("drivers/disk.zig");

const bss = @extern([*]u8, .{ .name = "__bss" });
const bss_end = @extern([*]u8, .{ .name = "__bss_end" });
const stack_top = @extern([*]align(16) u8, .{ .name = "__stack_top" });
const free_ram = @extern([*]u8, .{ .name = "__free_ram" });
const free_ram_end = @extern([*]u8, .{ .name = "__free_ram_end" });

pub const panic = std.debug.FullPanic(kernelPanic);

const shell_image = @embedFile("shell_image");

var heap: std.heap.FixedBufferAllocator = undefined;

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

    const heap_memory = free_ram[0 .. free_ram_end - free_ram];
    heap = std.heap.FixedBufferAllocator.init(heap_memory);

    // Disk
    disk.init(heap.allocator());
    var buffer: [512]u8 = undefined;
    disk.readWriteDisk(&buffer, 0, false);
    console.print("first sector: {s}\n", .{buffer[0..]}) catch {};

    // Display
    gpu.init(heap.allocator());

    @memset(buffer[0..], 0);
    const message = "hello from kernel!!!\n";
    @memcpy(buffer[0..message.len], message);
    disk.readWriteDisk(&buffer, 0, true);

    process.init(heap.allocator());
    _ = process.createProcess(heap.allocator(), shell_image);

    process.yield();
    @panic("switched to idle process");
}
