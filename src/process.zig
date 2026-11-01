const std = @import("std");
const memory = @import("memory.zig");
const context = @import("arch/riscv32/context.zig");

const PROCS_MAX: usize = 8;
const USER_BASE: usize = 0x0100_0000;
const SSTATUS_SPIE: usize = 1 << 5;

const free_ram_end = @extern([*]u8, .{ .name = "__free_ram_end" });

var processes: [PROCS_MAX]Process = undefined;
var current_proc: *Process = undefined;
var idle_proc: *Process = undefined;

const ProcessState = enum {
    Unused,
    Runnable,
    Exited,
};

const Process = struct {
    pid: u32,
    state: ProcessState,
    sp: usize,
    page_table: *memory.PageTable,
    stack: [8192]u8 align(16),
};

pub fn init(allocator: std.mem.Allocator) void {
    for (&processes) |*process| {
        process.* = .{
            .pid = 0,
            .state = .Unused,
            .sp = 0,
            .page_table = undefined,
            .stack = undefined,
        };
    }

    idle_proc = createProcess(allocator, &.{});
    idle_proc.pid = 0;
    current_proc = idle_proc;
}

pub fn yield() void {
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
    context.contextSwitch(&prev.sp, &next.sp);
}

pub fn createProcess(
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
            .fromByteUnits(memory.PAGE_SIZE),
            1024,
        ) catch @panic("out of memory for page table");
        @memset(entries, 0);

        const root: *memory.PageTable = entries[0..1024];

        var addr: usize = 0x8020_0000;
        while (addr < @intFromPtr(free_ram_end)) : (addr += memory.PAGE_SIZE) {
            memory.mapPage(
                allocator,
                root,
                addr,
                addr,
                memory.PageFlags.rwx,
            );
        }

        var offset: usize = 0;
        while (offset < image.len) : (offset += memory.PAGE_SIZE) {
            // allocate, zero, copy and map one page.
            const page = allocator.alignedAlloc(
                u8,
                .fromByteUnits(memory.PAGE_SIZE),
                memory.PAGE_SIZE,
            ) catch @panic("out of memory for application page");
            @memset(page, 0);

            const remaining = image.len - offset;
            const copy_size = @min(remaining, memory.PAGE_SIZE);

            @memcpy(page[0..copy_size], image[offset .. offset + copy_size]);

            memory.mapPage(
                allocator,
                root,
                USER_BASE + offset,
                @intFromPtr(page.ptr),
                memory.PageFlags.rwx | memory.PageFlags.user,
            );
        }

        const stack_end = @intFromPtr(&proc.stack) + proc.stack.len;
        const initial_context: *context.Context = @ptrFromInt(stack_end - @sizeOf(context.Context));

        initial_context.* = std.mem.zeroes(context.Context);
        initial_context.ra = @intFromPtr(&userEntry);

        proc.pid = i + 1;
        proc.state = .Runnable;
        proc.sp = @intFromPtr(initial_context);
        proc.page_table = root;

        return proc;
    }

    @panic("no free process slots");
}

pub fn currentPid() u32 {
    return current_proc.pid;
}

pub fn exitCurrent() noreturn {
    current_proc.state = .Exited;
    yield();
    @panic("exited process returned");
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
