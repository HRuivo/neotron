const std = @import("std");
const graphics = @import("framebuffer.zig");
const Color = graphics.Color;
const Point2D = graphics.Point2D;
const Font = @import("font.zig").Font;

const Cell = struct {
    character: u8 = ' ',
    fg: Color = Color.white(),
    bg: Color = Color.black(),
};

pub const TextConsole = struct {
    columns: usize,
    rows: usize,
    fb: *graphics.Framebuffer,
    font: *const Font,
    font_scale: usize,
    cursor_column: usize,
    cursor_row: usize,
    cells: []Cell,
    fg: Color,
    bg: Color,

    pub fn init(
        alloc: std.mem.Allocator,
        fb: *graphics.Framebuffer,
        font: *const Font,
        font_scale: usize,
    ) !TextConsole {
        const columns = fb.width / (Font.width * font_scale);
        const rows = fb.height / (Font.height * font_scale);
        const cells = try alloc.alloc(Cell, columns * rows);
        @memset(cells, Cell{});

        return .{
            .columns = columns,
            .rows = rows,
            .fb = fb,
            .cells = cells,
            .cursor_column = 0,
            .cursor_row = 0,
            .font = font,
            .font_scale = font_scale,
            .fg = Color.white(),
            .bg = Color.black(),
        };
    }

    pub fn render(self: TextConsole) void {
        for (self.cells, 0..) |cell, index| {
            const column = index % self.columns;
            const row = index / self.columns;

            self.fb.drawGlyph(
                self.font,
                self.font_scale,
                .{ .x = column * Font.width * self.font_scale, .y = row * Font.height * self.font_scale },
                cell.character,
                cell.fg,
                cell.bg,
            );
        }
    }

    pub fn setChar(self: TextConsole, character: u8, column: usize, row: usize) void {
        if (column >= self.columns or row >= self.rows) return;

        const cell_idx = row * self.columns + column;
        self.cells[cell_idx] = .{
            .character = character,
            .fg = self.fg,
            .bg = self.bg,
        };
    }

    pub fn putChar(self: *TextConsole, character: u8) void {
        if (self.cursor_row >= self.rows) return;
        switch (character) {
            '\n' => {
                self.cursor_column = 0;
                self.cursor_row += 1;
            },
            '\r' => {
                self.cursor_column = 0;
            },
            '\t' => {
                self.cursor_column += 4 - (self.cursor_column % 4);
            },
            '\x08' => {
                if (self.cursor_column > 0) self.cursor_column -= 1;
                self.setChar(' ', self.cursor_column, self.cursor_row);
            },
            else => {
                self.setChar(character, self.cursor_column, self.cursor_row);
                self.cursor_column += 1;
            },
        }
        if (self.cursor_column >= self.columns) {
            self.cursor_column = 0;
            self.cursor_row += 1;
        }
    }
};
