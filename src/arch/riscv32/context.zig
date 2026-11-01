pub const Context = extern struct {
    ra: usize,
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
    padding: [3]usize, // Preserve your current 64-byte frame.
};

comptime {
    if (@sizeOf(Context) != 64)
        @compileError("context frame must occupy 64 bytes");

    if (@offsetOf(Context, "s11") != 48)
        @compileError("s11 offset must match context-switch assembly");
}

pub fn contextSwitch(prev_sp: *usize, next_sp: *const usize) void {
    const switch_fn: *const fn (*usize, *const usize) callconv(.c) void =
        @ptrCast(&switchContext);
    @call(.never_inline, switch_fn, .{ prev_sp, next_sp });
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
