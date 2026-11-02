const std = @import("std");
const font = @import("font.zig");
const console = @import("../console.zig");

pub const Framebuffer = struct {
    pixels: []u8,
    width: u32,
    height: u32,
    size: usize,

    pub fn init(
        allocator: std.mem.Allocator,
        width: u32,
        height: u32,
    ) !Framebuffer {
        const size = @as(usize, width) * @as(usize, height);
        const byte_count = size * 4;
        const pixels = try allocator.alloc(u8, byte_count);
        @memset(pixels, 0);

        return .{
            .width = width,
            .height = height,
            .pixels = pixels,
            .size = size,
        };
    }

    pub fn putPixel(self: *Framebuffer, position: Point2D, colour: Color) void {
        if (position.x < self.width and position.y < self.height) {
            const byte_offset = (position.y * self.width + position.x) * 4;
            self.pixels[byte_offset + 0] = colour.b;
            self.pixels[byte_offset + 1] = colour.g;
            self.pixels[byte_offset + 2] = colour.r;
            self.pixels[byte_offset + 3] = colour.a;
        }
    }

    pub fn drawRect(self: *Framebuffer, position: Point2D, dimension: Point2D, colour: Color) void {
        if (position.x >= self.width or position.y >= self.height) return;
        const draw_width = @min(dimension.x, self.width - position.x);
        const draw_height = @min(dimension.y, self.height - position.y);
        for (0..draw_height) |row| {
            for (0..draw_width) |col| {
                self.putPixel(.{ .x = position.x + col, .y = position.y + row }, colour);
            }
        }
    }

    pub fn drawGlyph(self: *Framebuffer, position: Point2D, character: u8, fg: Color, bg: Color) void {
        const supported = if (character < 32 or character > 126) '?' else character;
        const glyph_offset = (supported - 32);

        const glyph = font.glyphs[glyph_offset];

        for (0..8) |row| {
            const row_bits = glyph[row];

            for (0..8) |col| {
                const mask = @as(u8, 1) << @as(u3, @intCast(col));
                const is_foreground = (row_bits & mask) != 0;
                const x = position.x + col * 2;
                const y = position.y + row * 2;
                self.drawRect(.{ .x = x, .y = y }, .{ .x = 2, .y = 2 }, if (is_foreground) fg else bg);
            }
        }
    }
};

pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8 = 255,

    pub fn white() Color {
        return .{
            .r = 255,
            .g = 255,
            .b = 255,
        };
    }

    pub fn black() Color {
        return .{
            .r = 0,
            .g = 0,
            .b = 0,
        };
    }

    pub fn red() Color {
        return .{
            .r = 255,
            .g = 0,
            .b = 0,
        };
    }

    pub fn green() Color {
        return .{
            .r = 0,
            .g = 255,
            .b = 0,
        };
    }

    pub fn blue() Color {
        return .{
            .r = 0,
            .g = 0,
            .b = 255,
        };
    }
};

pub const Point2D = struct {
    x: usize,
    y: usize,
};
