const graphics = @import("framebuffer.zig");
const Framebuffer = graphics.Framebuffer;
const Colour = graphics.Colour;

pub fn draw(framebuffer: *Framebuffer) void {
    for (0..framebuffer.height) |y| {
        for (0..framebuffer.width) |x| {
            framebuffer.putPixel(.{ .x = x, .y = y }, .{ .r = 19, .g = 128, .b = 134 });
        }
    }

    framebuffer.drawRect(.{ .x = 256, .y = 500 }, .{ .x = 255, .y = 120 }, Colour.white());
    framebuffer.drawRect(.{ .x = 100, .y = 100 }, .{ .x = 350, .y = 120 }, Colour.red());
}
