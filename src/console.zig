const sbi = @import("sbi.zig");

pub fn putChar(ch: u8) !void {
    const result = sbi.sbiCall(ch, 0, 0, 0, 0, 0, 0, 1);
    if (result.err < 0) {
        return error.ConsoleWriteFailed;
    }
}

pub fn writeBytes(bytes: []const u8) !usize {
    for (bytes) |b| {
        try putChar(b);
    }
    return bytes.len;
}
