const sbi = @import("sbi.zig");

const bss = @extern([*]u8, .{ .name = "__bss" });
const bss_end = @extern([*]u8, .{ .name = "__bss_end" });
const stack_top = @extern([*]align(16) u8, .{ .name = "__stack_top" });

export fn boot() linksection(".text.boot") callconv(.naked) void {
    asm volatile (
        \\mv sp, %[stack]
        \\j kernelMain
        :
        : [stack] "r" (stack_top),
    );
}

export fn kernelMain() noreturn {
    const bss_len = bss_end - bss;
    @memset(bss[0..bss_len], 0);

    const message: []const u8 = "\n\nHello World!\n";
    for (message) |c| {
        putChar(c);
    }

    while (true) asm volatile ("");
}

fn putChar(ch: u8) void {
    _ = sbi.sbiCall(ch, 0, 0, 0, 0, 0, 0, 1);
}
