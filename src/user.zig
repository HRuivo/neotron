const stack_top = @extern([*]u8, .{ .name = "__stack_top" });

export fn exit() noreturn {
    while (true) {}
}

pub fn putChar(ch: u8) void {
    _ = ch;
}

export fn start() linksection(".text.start") callconv(.naked) void {
    asm volatile (
        \\mv sp, %[stack]
        \\call main
        \\call exit
        :
        : [stack] "r" (stack_top),
    );
}
