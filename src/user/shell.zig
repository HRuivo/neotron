const std = @import("std");
const user = @import("runtime.zig");

comptime {
    _ = user;
}

export fn main() void {
    var buff: [128]u8 = undefined;
    var len: usize = 0;

    prompt: while (true) {
        len = 0;
        user.putString("> ");

        while (true) {
            const ch = user.getChar();
            user.putChar(ch);

            switch (ch) {
                '\r' => {
                    user.putChar('\n');
                    break;
                },
                else => {
                    if (len >= buff.len) {
                        user.putString("command line too long\n");
                        continue :prompt;
                    }
                    buff[len] = ch;
                    len += 1;
                },
            }
        }

        const command = buff[0..len];
        if (std.mem.eql(u8, command, "hello")) {
            user.putString("Hello world from shell!\n");
        } else if (std.mem.eql(u8, command, "quit")) {
            user.exit();
        } else {
            user.putString("unknown command!\n");
        }
    }
}
