const std = @import("std");

const console = @import("console.zig");
const syscall = @import("syscall");

const process = @import("process.zig");

const cpu = @import("arch/riscv32/cpu.zig");
const memory = @import("memory.zig");
const gpu = @import("drivers/gpu.zig");
const disk = @import("drivers/disk.zig");

const bss = @extern([*]u8, .{ .name = "__bss" });
const bss_end = @extern([*]u8, .{ .name = "__bss_end" });
const stack_top = @extern([*]align(16) u8, .{ .name = "__stack_top" });
const free_ram = @extern([*]u8, .{ .name = "__free_ram" });
const free_ram_end = @extern([*]u8, .{ .name = "__free_ram_end" });

pub const panic = std.debug.FullPanic(kernelPanic);

const SCAUSE_ECALL: usize = 0x8;

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
    cpu.writeCsr("stvec", @intFromPtr(&kernelEntry));

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

const TrapFrame = packed struct {
    ra: usize,
    gp: usize,
    tp: usize,
    t0: usize,
    t1: usize,
    t2: usize,
    t3: usize,
    t4: usize,
    t5: usize,
    t6: usize,
    a0: usize,
    a1: usize,
    a2: usize,
    a3: usize,
    a4: usize,
    a5: usize,
    a6: usize,
    a7: usize,
    s0: usize,
    s1: usize,
    s2: usize,
    s3: usize,
    s4: usize,
    s5: usize,
    s6: usize,
    s7: usize,
    s8: usize,
    s9: usize,
    s10: usize,
    s11: usize,
    sp: usize,
};

fn kernelEntry() align(4) callconv(.naked) void {
    asm volatile (
        \\csrrw sp, sscratch, sp
        \\
        \\addi sp, sp, -128
        \\sw ra, 4 * 0(sp)
        \\sw gp,  4 * 1(sp)
        \\sw tp,  4 * 2(sp)
        \\sw t0,  4 * 3(sp)
        \\sw t1,  4 * 4(sp)
        \\sw t2,  4 * 5(sp)
        \\sw t3,  4 * 6(sp)
        \\sw t4,  4 * 7(sp)
        \\sw t5,  4 * 8(sp)
        \\sw t6,  4 * 9(sp)
        \\sw a0,  4 * 10(sp)
        \\sw a1,  4 * 11(sp)
        \\sw a2,  4 * 12(sp)
        \\sw a3,  4 * 13(sp)
        \\sw a4,  4 * 14(sp)
        \\sw a5,  4 * 15(sp)
        \\sw a6,  4 * 16(sp)
        \\sw a7,  4 * 17(sp)
        \\sw s0,  4 * 18(sp)
        \\sw s1,  4 * 19(sp)
        \\sw s2,  4 * 20(sp)
        \\sw s3,  4 * 21(sp)
        \\sw s4,  4 * 22(sp)
        \\sw s5,  4 * 23(sp)
        \\sw s6,  4 * 24(sp)
        \\sw s7,  4 * 25(sp)
        \\sw s8,  4 * 26(sp)
        \\sw s9,  4 * 27(sp)
        \\sw s10, 4 * 28(sp)
        \\sw s11, 4 * 29(sp)
        \\
        \\csrr a0, sscratch
        \\sw a0, 4 * 30(sp)
        \\
        \\addi a0, sp, 128
        \\csrw sscratch, a0
        \\
        \\mv a0, sp
        \\call handleTrap
        \\
        \\lw ra,  4 * 0(sp)
        \\lw gp,  4 * 1(sp)
        \\lw tp,  4 * 2(sp)
        \\lw t0,  4 * 3(sp)
        \\lw t1,  4 * 4(sp)
        \\lw t2,  4 * 5(sp)
        \\lw t3,  4 * 6(sp)
        \\lw t4,  4 * 7(sp)
        \\lw t5,  4 * 8(sp)
        \\lw t6,  4 * 9(sp)
        \\lw a0,  4 * 10(sp)
        \\lw a1,  4 * 11(sp)
        \\lw a2,  4 * 12(sp)
        \\lw a3,  4 * 13(sp)
        \\lw a4,  4 * 14(sp)
        \\lw a5,  4 * 15(sp)
        \\lw a6,  4 * 16(sp)
        \\lw a7,  4 * 17(sp)
        \\lw s0,  4 * 18(sp)
        \\lw s1,  4 * 19(sp)
        \\lw s2,  4 * 20(sp)
        \\lw s3,  4 * 21(sp)
        \\lw s4,  4 * 22(sp)
        \\lw s5,  4 * 23(sp)
        \\lw s6,  4 * 24(sp)
        \\lw s7,  4 * 25(sp)
        \\lw s8,  4 * 26(sp)
        \\lw s9,  4 * 27(sp)
        \\lw s10, 4 * 28(sp)
        \\lw s11, 4 * 29(sp)
        \\lw sp,  4 * 30(sp)
        \\sret
    );
}

fn handleSyscall(tf: *TrapFrame) void {
    switch (tf.a3) {
        @backingInt(syscall.Number.putchar) => {
            console.putChar(@truncate(tf.a0)) catch @panic("console write failed");
        },
        @backingInt(syscall.Number.getchar) => {
            while (true) {
                if (console.getChar()) |ch| {
                    tf.a0 = ch;
                    break;
                }

                process.yield();
            }
        },
        @backingInt(syscall.Number.exit) => {
            console.print("process {d} exited\n", .{process.currentPid()}) catch {};
            process.exitCurrent();
        },
        else => std.debug.panic("unexpected syscall a3={x}", .{tf.a3}),
    }
}

export fn handleTrap(tf: *TrapFrame) void {
    const scause = cpu.readCsr("scause");
    const stval = cpu.readCsr("stval");
    var user_pc: usize = cpu.readCsr("sepc");

    switch (scause) {
        SCAUSE_ECALL => {
            handleSyscall(tf);
            user_pc += 4;
        },
        else => std.debug.panic(
            "unexpected trap scause=0x{x}, stval=0x{x}, sepc=0x{x}",
            .{ scause, stval, user_pc },
        ),
    }

    cpu.writeCsr("sepc", user_pc);
}
