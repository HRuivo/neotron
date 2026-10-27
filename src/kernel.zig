const stack_top = @extern([*]u8, .{ .name = "__stack_top" });

export fn boot() linksection(".text.boot") callconv(.naked) void {
    asm volatile (
        \\mv sp, %[stack]
        \\j kernelMain
        :
        : [stack] "r" (stack_top),
    );
}

export fn kernelMain() noreturn {
    while (true) asm volatile ("");
}
