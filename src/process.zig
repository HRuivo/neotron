const std = @import("std");
const memory = @import("memory.zig");
const cpu = @import("arch/riscv32/cpu.zig");
const context = @import("arch/riscv32/context.zig");

const PROCS_MAX: usize = 8;
const USER_BASE: usize = 0x0100_0000;
const SSTATUS_SPIE: usize = 1 << 5;

var processes: [PROCS_MAX]Process = undefined;
var current_proc: *Process = undefined;
var idle_proc: *Process = undefined;
var current_index: usize = 0;

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
    current_index = 0;
}

pub fn yield() void {
    var next: *Process = idle_proc;
    var next_index: usize = 0;

    // Start after the current process and wrap around for round-robin scheduling.
    for (1..PROCS_MAX + 1) |offset| {
        const index = (current_index + offset) % PROCS_MAX;
        const candidate = &processes[index];

        if (candidate.state == .Runnable and candidate != idle_proc) {
            next = candidate;
            next_index = index;
            break;
        }
    }

    if (next == current_proc) {
        return;
    }

    cpu.activatePageTable(@intFromPtr(next.page_table));

    cpu.writeCsr("sscratch", @intFromPtr(next.stack[0..].ptr + next.stack.len));

    const prev: *Process = current_proc;
    current_proc = next;
    current_index = next_index;

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
        const root = memory.createPageTable(allocator);

        memory.mapKernel(allocator, root);

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
