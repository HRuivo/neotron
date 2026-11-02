const graphics = @import("framebuffer.zig");
const Framebuffer = graphics.Framebuffer;
const Color = graphics.Color;
const font = @import("font.zig");

pub fn draw(framebuffer: *Framebuffer) void {
    for (0..framebuffer.height) |y| {
        for (0..framebuffer.width) |x| {
            framebuffer.putPixel(.{ .x = x, .y = y }, .{ .r = 19, .g = 128, .b = 134 });
        }
    }

    framebuffer.drawRect(.{ .x = 256, .y = 500 }, .{ .x = 255, .y = 120 }, Color.white());
    framebuffer.drawRect(.{ .x = 100, .y = 100 }, .{ .x = 350, .y = 120 }, Color.red());

    const default_font = font.default_font;

    var cursor: usize = 16;
    const message = "Hello World!";
    for (message) |ch| {
        framebuffer.drawGlyph(&default_font, 2, .{ .x = cursor, .y = 16 }, ch, Color.white(), Color.black());
        cursor += 16;
    }
}
