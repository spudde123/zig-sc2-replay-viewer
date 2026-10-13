const std = @import("std");
const sokol = @import("sokol");
const gfx = sokol.gfx;
const gl = sokol.gl;
const text = sokol.debugtext;
const formatGameTime = @import("playback.zig").formatGameTime;
const Image = @import("image.zig").Image;
const Frame = @import("image.zig").Frame;
const data = @import("replay_data.zig");
const chat_view = @import("chat_view.zig");
const projection = @import("camera_projection.zig");
const unit_overlay = @import("unit_overlay.zig");

pub const Overlay = struct {
    players: *const data.Players,
    chat: *const data.ChatQueue,
    chat_visible: bool = true,
    selected_tag: ?u64 = null,
    projection_markers: bool = false,
};

pub const Rect = projection.Rect;

const Texture = struct {
    image: gfx.Image = .{},
    view: gfx.View = .{},
    width: i32 = 0,
    height: i32 = 0,

    fn upload(self: *Texture, source: Image) void {
        if (self.width != source.width or self.height != source.height) {
            self.deinit();
            self.image = gfx.makeImage(.{
                .width = source.width,
                .height = source.height,
                .pixel_format = .RGBA8,
                .usage = .{ .write_transient = true },
            });
            self.view = gfx.makeView(.{ .texture = .{ .image = self.image } });
            self.width = source.width;
            self.height = source.height;
        }
        // Transient writes must happen before binding and on EVERY displayed frame,
        // not merely when SC2 produces new observations (including paused/end frames).
        gfx.writeImageTransient(.{
            .dst = .{ .image = self.image },
            .src = .{ .data = gfx.asRange(source.pixels) },
        });
    }

    fn deinit(self: *Texture) void {
        if (self.view.id != 0) gfx.destroyView(self.view);
        if (self.image.id != 0) gfx.destroyImage(self.image);
        self.* = .{};
    }
};

pub const Hud = struct {
    duration_loops: u32 = 0,
    labels: @import("player_labels.zig").Labels = .{},
    speed: f64 = 1,
    state: enum { loading, playing, paused, ended } = .loading,

    pub fn format(self: Hud, buffer: []u8, game_loop: u32) std.mem.PrintError![:0]const u8 {
        var current_buffer: [16]u8 = undefined;
        var duration_buffer: [16]u8 = undefined;
        const current = try formatGameTime(&current_buffer, game_loop);
        const duration = try formatGameTime(&duration_buffer, self.duration_loops);
        return std.mem.printSentinel(buffer, "{s} / {s} | {d}x | {s}\nLoop {d} / {d}", .{ current, duration, self.speed, @tagName(self.state), game_loop, self.duration_loops }, 0);
    }
};

pub const Renderer = struct {
    map: Texture = .{},
    minimap: Texture = .{},
    sampler: gfx.Sampler = .{},
    minimap_rect: Rect = .{},
    chat_button_rect: Rect = .{},
    map_rect: Rect = .{},
    hud_rect: Rect = .{},
    chat_rect: Rect = .{},
    order_box_rect: Rect = .{},

    pub fn init() Renderer {
        gfx.setup(.{ .environment = sokol.glue.environment(), .logger = .{ .func = sokol.log.func } });
        gl.setup(.{ .logger = .{ .func = sokol.log.func } });
        text.setup(.{
            .fonts = blk: {
                var fonts: [8]text.FontDesc = @splat(.{});
                fonts[0] = text.fontOric();
                // Chat needs ordinary ASCII punctuation (not Oric's currency
                // glyph in the underscore slot used by bot diagnostic tags).
                fonts[1] = text.fontCpc();
                break :blk fonts;
            },
            .logger = .{ .func = sokol.log.func },
        });
        return .{ .sampler = gfx.makeSampler(.{
            .min_filter = .LINEAR,
            .mag_filter = .LINEAR,
            .wrap_u = .CLAMP_TO_EDGE,
            .wrap_v = .CLAMP_TO_EDGE,
        }) };
    }

    pub fn deinit(self: *Renderer) void {
        self.map.deinit();
        self.minimap.deinit();
        gfx.destroySampler(self.sampler);
        text.shutdown();
        gl.shutdown();
        gfx.shutdown();
    }

    pub fn draw(self: *Renderer, frame: ?Frame, hud: Hud, overlay: Overlay) void {
        const width: f32 = @floatFromInt(sokol.app.width());
        const height: f32 = @floatFromInt(sokol.app.height());
        var hud_buffer: [512]u8 = undefined;
        const label = hud.format(&hud_buffer, if (frame) |f| f.game_loop else 0) catch unreachable;
        var columns: usize = 0;
        var lines: usize = 0;
        var row = std.mem.splitScalar(u8, label, '\n');
        while (row.next()) |line| {
            columns = @max(columns, line.len);
            lines += 1;
        }
        // Shrink the character cells only when the window is too narrow for the HUD.
        const cell_size = @min(16, @max(1, width - 40) / @as(f32, @floatFromInt(columns)));
        const hud_right = 12 + @as(f32, @floatFromInt(columns)) * cell_size + 16;
        const hud_bottom = 12 + @as(f32, @floatFromInt(lines)) * cell_size + 16;
        self.hud_rect = .{ .x = 12, .y = 12, .width = hud_right - 12, .height = hud_bottom - 12 };
        self.minimap_rect = .{};
        self.map_rect = .{};
        self.order_box_rect = .{};
        if (frame) |f| {
            self.map_rect = Rect.fit(@floatFromInt(f.map.width), @floatFromInt(f.map.height), width, height);
            if (f.minimap != null) {
                const side = @min(180, @min(width, height) * 0.28);
                self.minimap_rect = .{ .x = 12, .y = height - side - 12, .width = side, .height = side };
            }
        }
        self.chat_rect = if (overlay.chat_visible) chatRect(width, height, self.minimap_rect) else .{};
        self.chat_button_rect = chatButtonRect(width, height);
        gl.defaults();
        gl.matrixModeProjection();
        gl.ortho(0, width, height, 0, -1, 1);
        if (frame) |f| {
            self.map.upload(f.map);
            self.quad(self.map.view, self.map_rect);
            self.order_box_rect = unit_overlay.draw(&f.scene, overlay.selected_tag, overlay.projection_markers, .{
                .viewport = self.map_rect,
                .image_width = @floatFromInt(f.map.width),
                .image_height = @floatFromInt(f.map.height),
                .window_width = width,
                .window_height = height,
                .obstacles = &.{ self.hud_rect, self.minimap_rect, self.chat_rect, self.chat_button_rect },
            });
            if (f.minimap) |m| {
                self.minimap.upload(m);
                const rect = self.minimap_rect;
                solidRect(.{ .x = rect.x - 2, .y = rect.y - 2, .width = rect.width + 4, .height = rect.height + 4 }, .{ 0.2, 0.23, 0.28 });
                self.quad(self.minimap.view, rect);
            }
        }
        solidRect(self.hud_rect, .{ 0, 0, 0 });
        text.font(0);
        text.canvas(width * 8 / cell_size, height * 8 / cell_size);
        text.origin(20 / cell_size, 20 / cell_size);
        text.home();
        text.color3b(255, 255, 255);
        text.puts(label);
        if (self.minimap_rect.width > 0) self.drawPlayerLabels(hud.labels, width, height);
        if (overlay.chat_visible) self.drawChat(overlay, width, height);
        self.drawChatButton(overlay.chat_visible, width, height);
        gfx.beginPass(.{
            .swapchain = sokol.glue.swapchain(),
            .action = .{ .colors = blk: {
                var colors: [8]gfx.ColorAttachmentAction = @splat(.{});
                colors[0] = .{ .load_action = .CLEAR, .clear_value = .{ .r = 0.035, .g = 0.035, .b = 0.045, .a = 1 } };
                break :blk colors;
            } },
        });
        gl.draw();
        text.draw();
        gfx.endPass();
        gfx.commit();
    }

    pub fn blocksWorldClick(self: *const Renderer, x: f32, y: f32) bool {
        return self.hud_rect.contains(x, y) or self.chat_rect.contains(x, y) or
            self.chat_button_rect.contains(x, y) or self.order_box_rect.contains(x, y);
    }

    fn drawPlayerLabels(self: *Renderer, labels: @import("player_labels.zig").Labels, width: f32, height: f32) void {
        const rect = self.minimap_rect;
        if (rect.width < 8 or rect.height < 8) return;
        text.color3b(255, 255, 255);
        for (labels.items[0..labels.count]) |label| {
            const name = std.mem.sliceTo(&label.name, 0);
            const cell: f32 = @min(8, (rect.width - 4) / @as(f32, @floatFromInt(@max(1, name.len))));
            text.canvas(width * 8 / cell, height * 8 / cell);
            const px = rect.x + label.x * rect.width;
            const py = rect.y + (1 - label.y) * rect.height;
            solidRect(.{ .x = px - 2, .y = py - 2, .width = 4, .height = 4 }, .{ 1, 1, 1 });
            // Keep long labels and bases near the edge inside the minimap.
            const label_width = @as(f32, @floatFromInt(name.len)) * cell;
            const x = std.math.clamp(px - label_width / 2, rect.x, @max(rect.x, rect.x + rect.width - label_width));
            const y = std.math.clamp(py + 5, rect.y, rect.y + rect.height - cell);
            solidRect(.{ .x = x - 1, .y = y - 1, .width = label_width + 2, .height = cell + 2 }, .{ 0, 0, 0 });
            text.origin(x / cell, y / cell);
            text.home();
            text.puts(&label.name);
        }
    }

    fn drawChat(self: *Renderer, overlay: Overlay, width: f32, height: f32) void {
        const rect = chatRect(width, height, self.minimap_rect);
        if (rect.width == 0) return;
        const cell: f32 = 12;
        const columns: usize = @intFromFloat(@floor((rect.width - 20) / cell));
        const rows: usize = @intFromFloat(@floor((rect.height - 40) / cell));
        const layout = chat_view.build(overlay.chat, overlay.players, columns, rows);
        solidRect(.{ .x = rect.x - 1, .y = rect.y - 1, .width = rect.width + 2, .height = rect.height + 2 }, .{ 0.2, 0.23, 0.28 });
        solidRect(rect, .{ 0.04, 0.05, 0.07 });
        text.font(1);
        text.canvas(width * 8 / cell, height * 8 / cell);
        text.origin((rect.x + 10) / cell, (rect.y + 8) / cell);
        text.home();
        text.color3b(170, 200, 230);
        text.puts(if (overlay.chat.omitted > 0) "Chat *" else "Chat");
        text.color3b(235, 235, 235);
        if (layout.count == 0) {
            text.origin((rect.x + 10) / cell, (rect.y + 32) / cell);
            text.home();
            text.puts(if (columns >= 16) "No messages yet." else "(empty)");
        } else {
            for (layout.lines[0..layout.count], 0..) |*line, i| {
                text.origin((rect.x + 10) / cell, (rect.y + 32 + @as(f32, @floatFromInt(i)) * cell) / cell);
                text.home();
                text.puts(std.mem.sliceTo(&line.bytes, 0));
            }
        }
    }

    fn drawChatButton(self: *Renderer, visible: bool, width: f32, height: f32) void {
        self.chat_button_rect = chatButtonRect(width, height);
        const rect = self.chat_button_rect;
        if (rect.width == 0) return;
        solidRect(.{ .x = rect.x - 1, .y = rect.y - 1, .width = rect.width + 2, .height = rect.height + 2 }, if (visible) .{ 0.35, 0.55, 0.7 } else .{ 0.2, 0.23, 0.28 });
        solidRect(rect, .{ 0.08, 0.12, 0.17 });
        const cell: f32 = 12;
        text.font(1);
        text.canvas(width * 8 / cell, height * 8 / cell);
        text.origin((rect.x + 12) / cell, (rect.y + 8) / cell);
        text.home();
        text.color3b(235, 235, 235);
        text.puts(if (visible) "Hide chat" else "Show chat");
    }

    fn solidRect(rect: Rect, color: [3]f32) void {
        gl.disableTexture();
        gl.c4f(color[0], color[1], color[2], 1);
        gl.beginQuads();
        gl.v2f(rect.x, rect.y);
        gl.v2f(rect.x + rect.width, rect.y);
        gl.v2f(rect.x + rect.width, rect.y + rect.height);
        gl.v2f(rect.x, rect.y + rect.height);
        gl.end();
    }

    fn quad(self: *Renderer, view: gfx.View, rect: Rect) void {
        gl.enableTexture();
        gl.texture(view, self.sampler);
        gl.c4f(1, 1, 1, 1);
        gl.beginQuads();
        gl.v2fT2f(rect.x, rect.y, 0, 0);
        gl.v2fT2f(rect.x + rect.width, rect.y, 1, 0);
        gl.v2fT2f(rect.x + rect.width, rect.y + rect.height, 1, 1);
        gl.v2fT2f(rect.x, rect.y + rect.height, 0, 1);
        gl.end();
    }
};

/// Keep the passive chat panel beside the minimap, never over its controls.
fn chatRect(width: f32, height: f32, minimap: Rect) Rect {
    const left = if (minimap.width > 0) minimap.x + minimap.width + 12 else 12;
    const panel_width = @min(480, width - left - 12);
    const panel_height = @min(200, height * 0.32);
    if (panel_width < 160 or panel_height < 72) return .{};
    // Reserve the bottom row for the always-available visibility button.
    return .{ .x = width - panel_width - 12, .y = height - panel_height - 52, .width = panel_width, .height = panel_height };
}

fn chatButtonRect(width: f32, height: f32) Rect {
    // Below this size there is no usable space beside the minimap / below HUD.
    if (width < 240 or height < 140) return .{};
    return .{ .x = width - 144, .y = height - 40, .width = 132, .height = 28 };
}

test "chat button stays inside the window, outside chat and minimap" {
    const minimap: Rect = .{ .x = 12, .y = 528, .width = 180, .height = 180 };
    const panel = chatRect(960, 720, minimap);
    const button = chatButtonRect(960, 720);
    try std.testing.expect(button.x > minimap.x + minimap.width);
    try std.testing.expect(button.y >= panel.y + panel.height + 12);
    try std.testing.expect(button.x + button.width <= 960);
    try std.testing.expect(button.y + button.height <= 720);
    try std.testing.expect(button.contains(850, 690));
    try std.testing.expect(!button.contains(800, 690));
    try std.testing.expectEqual(@as(f32, 0), chatButtonRect(200, 720).width);
    try std.testing.expectEqual(@as(f32, 0), chatButtonRect(960, 100).width);
}

test "chat panel fits beside the minimap and hides rather than overlapping on tiny windows" {
    const minimap: Rect = .{ .x = 12, .y = 528, .width = 180, .height = 180 };
    const rect = chatRect(960, 720, minimap);
    try std.testing.expect(rect.x >= minimap.x + minimap.width + 12);
    try std.testing.expect(rect.x + rect.width <= 960);
    try std.testing.expect(rect.y + rect.height <= 720);
    try std.testing.expectEqual(@as(f32, 0), chatRect(320, 720, minimap).width);
    try std.testing.expectEqual(@as(f32, 0), chatRect(960, 100, minimap).width);
}

test "HUD shows frame time, duration, speed, state and loop counts" {
    var buffer: [512]u8 = undefined;
    const hud: Hud = .{ .duration_loops = 14884, .speed = 0.25, .state = .paused };
    try std.testing.expectEqualStrings(
        "01:00 / 11:04 | 0.25x | paused\nLoop 1344 / 14884",
        try hud.format(&buffer, 1344),
    );
    const loading: Hud = .{};
    try std.testing.expect(std.mem.startsWith(u8, try loading.format(&buffer, 0), "00:00 / 00:00 | 1x | loading\n"));
    const ended: Hud = .{ .duration_loops = 14884, .state = .ended };
    try std.testing.expect(std.mem.startsWith(u8, try ended.format(&buffer, 14884), "11:04 / 11:04 | 1x | ended\n"));
}

test "minimap hit testing" {
    const rect: Rect = .{ .x = 10, .y = 20, .width = 100, .height = 100 };
    try std.testing.expect(rect.contains(10, 20));
    try std.testing.expect(!rect.contains(110, 50));
    try std.testing.expect(!rect.contains(9, 50));
}
