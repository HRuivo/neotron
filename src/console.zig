const std = @import("std");
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

pub fn print(comptime fmt: []const u8, args: anytype) std.Io.Writer.Error!void {
    return console.print(fmt, args);
}

var console: std.Io.Writer = .{
    .buffer = &.{},
    .end = 0,
    .vtable = &.{ .drain = drain },
};

fn drain(_: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
    var byte_count: usize = 0;
    for (data[0 .. data.len - 1]) |bytes| {
        byte_count += writeBytes(bytes) catch return error.WriteFailed;
    }

    for (0..splat) |_| {
        byte_count += writeBytes(data[data.len - 1]) catch return error.WriteFailed;
    }

    return byte_count;
}
