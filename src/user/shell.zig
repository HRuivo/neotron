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

            switch (ch) {
                '\r', '\n' => {
                    user.putString("\r\n");
                    break;
                },

                '\x08', '\x7f' => {
                    if (len > 0) {
                        len -= 1;

                        // Move left, erase the character, move left again.
                        user.putString("\x08 \x08");
                    }
                },

                else => {
                    // Ignore other control characters.
                    if (ch < 32 or ch > 126) continue;

                    if (len >= buff.len) {
                        user.putString("\r\ncommand line too long\r\n");
                        continue :prompt;
                    }
                    buff[len] = ch;
                    len += 1;
                    user.putChar(ch);
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
