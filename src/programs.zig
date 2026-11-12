const syscall = @import("syscall");

pub const shell_image = @embedFile("shell_image");

const Image = struct {
    program: syscall.Program,
    bytes: []const u8,
};

const images = [_]Image{
    .{ .program = .hello, .bytes = @embedFile("hello_image") },
};

pub fn lookup(program_id: usize) ?[]const u8 {
    for (images) |image| {
        if (@backingInt(image.program) == program_id) return image.bytes;
    }
    return null;
}
