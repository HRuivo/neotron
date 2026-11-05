const std = @import("std");
const sbi_console = @import("sbi_console.zig");
const gpu = @import("../drivers/gpu.zig");
const TextConsole = @import("../graphics/text_console.zig").TextConsole;

var graphical: ?*TextConsole = null;
var dirty = false;

const input_capacity = 256;
var input_buffer: [input_capacity]u8 = undefined;
var input_head: usize = 0;
var input_count: usize = 0;

var console_writer: std.Io.Writer = .{
    .buffer = &.{},
    .end = 0,
    .vtable = &.{ .drain = drain },
};

pub fn attachGraphics(text_console: *TextConsole) void {
    graphical = text_console;
    dirty = true;
}

pub fn putChar(ch: u8) !void {
    // update graphics even if the SBI write subsequently fails.
    if (graphical) |text_console| {
        text_console.putChar(ch);
        dirty = true;
    }

    try sbi_console.putChar(ch);
}

pub fn writeBytes(bytes: []const u8) !usize {
    for (bytes) |ch| {
        try putChar(ch);
    }
    return bytes.len;
}

pub fn print(
    comptime fmt: []const u8,
    args: anytype,
) std.Io.Writer.Error!void {
    defer flush();
    return console_writer.print(fmt, args);
}

pub fn flush() void {
    const text_console = graphical orelse return;
    if (!dirty) return;

    text_console.render();
    gpu.present();
    dirty = false;
}

pub fn enqueueInput(ch: u8) bool {
    if (input_count == input_capacity) return false;

    const tail = (input_head + input_count) % input_capacity;
    input_buffer[tail] = ch;
    input_count += 1;
    return true;
}

pub fn getChar() ?u8 {
    if (input_count > 0) {
        const ch = input_buffer[input_head];
        input_head = (input_head + 1) % input_capacity;
        input_count -= 1;
        return ch;
    }

    return sbi_console.getChar();
}

fn drain(
    _: *std.Io.Writer,
    data: []const []const u8,
    splat: usize,
) std.Io.Writer.Error!usize {
    var count: usize = 0;

    for (data[0 .. data.len - 1]) |bytes| {
        count += writeBytes(bytes) catch return error.WriteFailed;
    }

    for (0..splat) |_| {
        count += writeBytes(data[data.len - 1]) catch
            return error.WriteFailed;
    }

    return count;
}
