const std = @import("std");
const console = @import("console.zig");
const syscall = @import("syscall.zig");
const disk = @import("disk.zig");
const display = @import("display.zig");

const bss = @extern([*]u8, .{ .name = "__bss" });
const bss_end = @extern([*]u8, .{ .name = "__bss_end" });
const stack_top = @extern([*]align(16) u8, .{ .name = "__stack_top" });

const free_ram = @extern([*]u8, .{ .name = "__free_ram" });
const free_ram_end = @extern([*]u8, .{ .name = "__free_ram_end" });

pub const panic = std.debug.FullPanic(kernelPanic);

var heap: std.heap.FixedBufferAllocator = undefined;

const PAGE_SIZE: usize = 4096;
const PageTable = [1024]u32;
const PROCS_MAX: usize = 8;
const USER_BASE: usize = 0x0100_0000;
const SSTATUS_SPIE: usize = 1 << 5;
const SCAUSE_ECALL: usize = 0x8;

const PageFlags = struct {
    const valid: u32 = 1 << 0;
    const read: u32 = 1 << 1;
    const write: u32 = 1 << 2;
    const execute: u32 = 1 << 3;
    const user: u32 = 1 << 4;

    const rw: u32 = read | write;
    const rx: u32 = read | execute;
    const rwx: u32 = read | write | execute;
};

var processes: [PROCS_MAX]Process = undefined;

var current_proc: *Process = undefined;
var idle_proc: *Process = undefined;

const shell_image = @embedFile("shell_image");

const ProcessState = enum {
    Unused,
    Runnable,
    Exited,
};

const Process = struct {
    pid: u32,
    state: ProcessState,
    sp: usize,
    page_table: *PageTable,
    stack: [8192]u8 align(16),
};

fn yield() void {
    var next: *Process = idle_proc;

    // Start after the current process and wrap around for round-robin scheduling.
    for (1..PROCS_MAX + 1) |offset| {
        const process = &processes[(current_proc.pid - 1 + offset) % PROCS_MAX];
        if (process.state == .Runnable and process.pid > 0) {
            next = process;
            break;
        }
    }

    if (next == current_proc) {
        return;
    }

    const ppn = @intFromPtr(next.page_table) >> 12;
    const sv32 = @as(usize, 1) << 31;
    const satp_value = sv32 | ppn;

    asm volatile (
        \\sfence.vma
        \\csrw satp, %[value]
        \\sfence.vma
        :
        : [value] "r" (satp_value),
        : .{ .memory = true });

    asm volatile ("csrw sscratch, %[sscratch]"
        :
        : [sscratch] "r" (@intFromPtr(next.stack[0..].ptr + next.stack.len)),
    );

    const prev: *Process = current_proc;
    current_proc = next;
    contextSwitch(&prev.sp, &next.sp);
}

fn switchContext(prev_sp: *usize, next_sp: *const usize) callconv(.naked) void {
    // a0 = prev_sp
    // a1 = next_sp
    _ = prev_sp;
    _ = next_sp;

    asm volatile (
    // Save callee-saved registers onto the current process's stack.
        \\addi sp, sp, -16 * 4
        \\sw ra,  0  * 4(sp)
        \\sw s0,  1  * 4(sp)
        \\sw s1,  2  * 4(sp)
        \\sw s2,  3  * 4(sp)
        \\sw s3,  4  * 4(sp)
        \\sw s4,  5  * 4(sp)
        \\sw s5,  6  * 4(sp)
        \\sw s6,  7  * 4(sp)
        \\sw s7,  8  * 4(sp)
        \\sw s8,  9  * 4(sp)
        \\sw s9,  10 * 4(sp)
        \\sw s10, 11 * 4(sp)
        \\sw s11, 12 * 4(sp)

        // Switch the stack pointer.
        \\sw sp, (a0)
        \\lw sp, (a1)

        // Restore callee-saved registers from the next process's stack.
        \\lw ra,  0  * 4(sp)
        \\lw s0,  1  * 4(sp)
        \\lw s1,  2  * 4(sp)
        \\lw s2,  3  * 4(sp)
        \\lw s3,  4  * 4(sp)
        \\lw s4,  5  * 4(sp)
        \\lw s5,  6  * 4(sp)
        \\lw s6,  7  * 4(sp)
        \\lw s7,  8  * 4(sp)
        \\lw s8,  9  * 4(sp)
        \\lw s9,  10 * 4(sp)
        \\lw s10, 11 * 4(sp)
        \\lw s11, 12 * 4(sp)
        \\addi sp, sp, 16 * 4
        \\ret
    );
}

fn contextSwitch(prev_sp: *usize, next_sp: *const usize) void {
    const switch_fn: *const fn (*usize, *const usize) callconv(.c) void =
        @ptrCast(&switchContext);
    @call(.never_inline, switch_fn, .{ prev_sp, next_sp });
}

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

fn userEntry() callconv(.naked) noreturn {
    asm volatile (
        \\csrw sepc, %[sepc]
        \\csrw sstatus, %[sstatus]
        \\sret
        :
        : [sepc] "r" (USER_BASE),
          [sstatus] "r" (SSTATUS_SPIE),
    );

    unreachable;
}

fn createProcess(
    allocator: std.mem.Allocator,
    image: []const u8,
) *Process {
    var free_proc: ?*Process = null;

    var i: usize = 0;
    for (&processes) |*process| {
        if (process.state == .Unused) {
            free_proc = process;
            break;
        }
        i += 1;
    }

    if (free_proc) |proc| {
        const entries = allocator.alignedAlloc(
            u32,
            .fromByteUnits(PAGE_SIZE),
            1024,
        ) catch @panic("out of memory for page table");
        @memset(entries, 0);

        const root: *PageTable = entries[0..1024];

        var addr: usize = 0x8020_0000;
        while (addr < @intFromPtr(free_ram_end)) : (addr += PAGE_SIZE) {
            mapPage(
                allocator,
                root,
                addr,
                addr,
                PageFlags.rwx,
            );
        }

        var offset: usize = 0;
        while (offset < image.len) : (offset += PAGE_SIZE) {
            // allocate, zero, copy and map one page.
            const page = allocator.alignedAlloc(
                u8,
                .fromByteUnits(PAGE_SIZE),
                PAGE_SIZE,
            ) catch @panic("out of memory for application page");
            @memset(page, 0);

            const remaining = image.len - offset;
            const copy_size = @min(remaining, PAGE_SIZE);

            @memcpy(page[0..copy_size], image[offset .. offset + copy_size]);

            mapPage(
                allocator,
                root,
                USER_BASE + offset,
                @intFromPtr(page.ptr),
                PageFlags.rwx | PageFlags.user,
            );
        }

        var sp: [*]usize = @ptrCast(@alignCast(proc.stack[0..].ptr + proc.stack.len));
        sp -= 3;
        sp -= 1;
        sp[0] = 0; // s11
        sp -= 1;
        sp[0] = 0; // s10
        sp -= 1;
        sp[0] = 0; // s9
        sp -= 1;
        sp[0] = 0; // s8
        sp -= 1;
        sp[0] = 0; // s7
        sp -= 1;
        sp[0] = 0; // s6
        sp -= 1;
        sp[0] = 0; // s5
        sp -= 1;
        sp[0] = 0; // s4
        sp -= 1;
        sp[0] = 0; // s3
        sp -= 1;
        sp[0] = 0; // s2
        sp -= 1;
        sp[0] = 0; // s1
        sp -= 1;
        sp[0] = 0; // s0
        sp -= 1;
        sp[0] = @intFromPtr(&userEntry); // ra

        proc.pid = i + 1;
        proc.state = .Runnable;
        proc.sp = @intFromPtr(sp);
        proc.page_table = root;

        return proc;
    }

    @panic("no free process slots");
}

fn mapPage(
    allocator: std.mem.Allocator,
    root: *PageTable,
    vaddr: usize,
    paddr: usize,
    flags: u32,
) void {
    if (!std.mem.isAligned(vaddr, PAGE_SIZE) or !std.mem.isAligned(paddr, PAGE_SIZE)) {
        std.debug.panic("could not create a page table for an unaligned address: v{x} p{x}\n", .{ vaddr, paddr });
    }

    const vpn1 = (vaddr >> 22) & 0x3ff;
    if ((root[vpn1] & PageFlags.valid) == 0) {
        const new_table = allocator.alignedAlloc(
            u32,
            .fromByteUnits(PAGE_SIZE),
            1024,
        ) catch @panic("out of memory for page table");
        @memset(new_table, 0);

        const table_paddr = @intFromPtr(new_table.ptr);
        const table_ppn = table_paddr >> 12;

        root[vpn1] = (table_ppn << 10) | 0b1;
    }

    const table_paddr = (root[vpn1] >> 10) << 12;
    const table: *PageTable = @ptrFromInt(table_paddr);
    const vpn0 = (vaddr >> 12) & 0x3ff;
    const ppn = paddr >> 12;
    table[vpn0] = (ppn << 10) | flags | PageFlags.valid;
}

export fn kernelMain() noreturn {
    const bss_len = bss_end - bss;
    @memset(bss[0..bss_len], 0);
    writeCsr("stvec", @intFromPtr(&kernelEntry));

    const heap_memory = free_ram[0 .. free_ram_end - free_ram];
    heap = std.heap.FixedBufferAllocator.init(heap_memory);

    // Disk
    disk.init(heap.allocator());
    var buffer: [512]u8 = undefined;
    disk.readWriteDisk(&buffer, 0, false);
    console.print("first sector: {s}\n", .{buffer[0..]}) catch {};

    // Display
    display.init(heap.allocator());

    @memset(buffer[0..], 0);
    const message = "hello from kernel!!!\n";
    @memcpy(buffer[0..message.len], message);
    disk.readWriteDisk(&buffer, 0, true);

    for (&processes) |*process| {
        process.* = .{
            .pid = 0,
            .state = .Unused,
            .sp = 0,
            .page_table = undefined,
            .stack = undefined,
        };
    }

    idle_proc = createProcess(heap.allocator(), &.{});
    idle_proc.pid = 0;
    current_proc = idle_proc;

    _ = createProcess(heap.allocator(), shell_image);

    console.print("shell image: {d} bytes, first byte: 0x{x}\n", .{
        shell_image.len,
        shell_image[0],
    }) catch {};

    console.print("embedded shell address: 0x{x}\n", .{
        @intFromPtr(shell_image),
    }) catch {};

    yield();
    @panic("switched to idle process");
    //while (true) asm volatile ("");
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
        \\addi a0, sp, 4 * 31
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

                yield();
            }
        },
        @backingInt(syscall.Number.exit) => {
            console.print("process {d} exited\n", .{current_proc.pid}) catch {};
            current_proc.state = .Exited;
            yield();
            @panic("exited process resumed");
        },
        else => std.debug.panic("unexpected syscall a3={x}", .{tf.a3}),
    }
}

export fn handleTrap(tf: *TrapFrame) void {
    const scause = readCsr("scause");
    const stval = readCsr("stval");
    var user_pc: usize = readCsr("sepc");

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

    writeCsr("sepc", user_pc);
}

pub inline fn readCsr(comptime reg: []const u8) usize {
    return asm volatile ("csrr %[result], " ++ reg
        : [result] "=r" (-> usize),
    );
}

pub inline fn writeCsr(comptime reg: []const u8, value: usize) void {
    asm volatile ("csrw " ++ reg ++ ", %[value]"
        :
        : [value] "r" (value),
    );
}
