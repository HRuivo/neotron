const syscall = @import("syscall");

const stack_top = @extern([*]u8, .{ .name = "__stack_top" });

pub fn putChar(ch: u8) void {
    _ = sysCall(.putchar, ch, 0, 0);
}

pub fn putString(string: []const u8) void {
    for (string) |ch| {
        putChar(ch);
    }
}

pub fn getChar() u8 {
    return @truncate(sysCall(.getchar, 0, 0, 0));
}

pub fn spawn(program: syscall.Program) usize {
    return sysCall(.spawn, @backingInt(program), 0, 0);
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

pub export fn exit() noreturn {
    _ = sysCall(.exit, 0, 0, 0);
    unreachable;
}

pub fn sysCall(
    number: syscall.Number,
    arg0: usize,
    arg1: usize,
    arg2: usize,
) usize {
    var a0: usize = undefined;

    asm volatile ("ecall"
        : [a0] "={a0}" (a0),
        : [arg0] "{a0}" (arg0),
          [arg1] "{a1}" (arg1),
          [arg2] "{a2}" (arg2),
          [sysno] "{a3}" (@backingInt(number)),
        : .{ .memory = true });

    return a0;
}
