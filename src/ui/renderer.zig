const std = @import("std");
const sokol = @import("sokol");
const gfx = sokol.gfx;
const gl = sokol.gl;
const text = sokol.debugtext;
const formatGameTime = @import("../replay/playback.zig").formatGameTime;
const Image = @import("../replay/image.zig").Image;
const Frame = @import("../replay/image.zig").Frame;
const data = @import("../replay/replay_data.zig");
const chat_view = @import("chat_view.zig");
const projection = @import("../camera/camera_projection.zig");
const unit_overlay = @import("unit_overlay.zig");
const production = @import("production_view.zig");
const stats_view = @import("player_stats_view.zig");
const inventory = @import("inventory_view.zig");

pub const Overlay = struct {
    players: *const data.Players,
    chat: *const data.ChatQueue,
    chat_visible: bool = false,
    production_visible: bool = true,
    production_tab: inventory.Tab = .production,
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
    labels: @import("../replay/player_labels.zig").Labels = .{},
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
    info_rect: Rect = .{},
    stats_rect: Rect = .{},
    production_rect: Rect = .{},
    production_button_rect: Rect = .{},
    production_tab_rects: [3]Rect = @splat(.{}),
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
        self.production_rect = productionRect(width, height, self.hud_rect, self.minimap_rect, self.chat_rect);
        var production_layout: production.Layout = .{};
        if (self.production_rect.width > 0) {
            const rows: usize = @intFromFloat(@floor((self.production_rect.height - 32) / 18));
            const production_columns: usize = @intFromFloat(@floor((self.production_rect.width - 20) / 10));
            const label_columns: usize = @intFromFloat(@floor((self.production_rect.width - 214) / 10));
            if (overlay.production_visible) {
                if (overlay.production_tab == .production) {
                    const summary = if (frame) |f| production.summarize(&f.scene) else production.Summary{};
                    production_layout = production.build(&summary, overlay.players, rows, production_columns, label_columns);
                } else {
                    const summary = if (frame) |f| inventory.summarize(&f.scene, overlay.production_tab == .structures) else inventory.Summary{};
                    production_layout = inventory.build(&summary, overlay.players, rows, production_columns);
                }
            }
            self.production_rect.height = 32 + @as(f32, @floatFromInt(production_layout.count)) * 18;
            self.production_button_rect = .{ .x = self.production_rect.x + self.production_rect.width - 66, .y = self.production_rect.y + 4, .width = 56, .height = 22 };
            var tab_x = self.production_rect.x + 6;
            for (&self.production_tab_rects, 0..) |*rect, i| {
                rect.* = .{ .x = tab_x, .y = self.production_rect.y + 4, .width = if (i == 0) 60 else 36, .height = 22 };
                tab_x += rect.width + 4;
            }
        } else {
            self.production_button_rect = .{};
            self.production_tab_rects = @splat(.{});
        }
        self.info_rect = self.hud_rect;
        if (self.production_rect.width > 0) {
            self.info_rect.width = self.production_rect.width;
            self.info_rect.height = self.production_rect.y + self.production_rect.height - self.info_rect.y;
        }
        var stats_layout: stats_view.Layout = .{};
        self.stats_rect = playerStatsRect(width, height, self.info_rect, self.minimap_rect, self.chat_rect);
        if (self.stats_rect.width > 0) {
            const stats_rows: usize = @intFromFloat(@floor((self.stats_rect.height - 26) / 14));
            stats_layout = stats_view.build(overlay.players, if (frame) |f| f.player_stats else .{}, stats_rows);
            self.stats_rect.height = 26 + @as(f32, @floatFromInt(stats_layout.count)) * 14;
        }
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
                .obstacles = &.{ self.info_rect, self.stats_rect, self.minimap_rect, self.chat_rect, self.chat_button_rect },
            });
            if (f.minimap) |m| {
                self.minimap.upload(m);
                const rect = self.minimap_rect;
                solidRect(.{ .x = rect.x - 2, .y = rect.y - 2, .width = rect.width + 4, .height = rect.height + 4 }, .{ 0.2, 0.23, 0.28 });
                self.quad(self.minimap.view, rect);
            }
        }
        solidRect(.{ .x = self.info_rect.x - 1, .y = self.info_rect.y - 1, .width = self.info_rect.width + 2, .height = self.info_rect.height + 2 }, .{ 0.2, 0.23, 0.28 });
        solidRect(self.info_rect, .{ 0.04, 0.05, 0.07 });
        text.font(0);
        text.canvas(width * 8 / cell_size, height * 8 / cell_size);
        text.origin(20 / cell_size, 20 / cell_size);
        text.home();
        text.color3b(255, 255, 255);
        text.puts(label);
        self.drawPlayerStats(&stats_layout, width, height);
        self.drawProduction(&production_layout, overlay.production_visible, overlay.production_tab, width, height);
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
        return self.info_rect.contains(x, y) or self.stats_rect.contains(x, y) or self.chat_rect.contains(x, y) or
            self.chat_button_rect.contains(x, y) or self.order_box_rect.contains(x, y);
    }

    fn drawPlayerStats(self: *Renderer, layout: *const stats_view.Layout, width: f32, height: f32) void {
        const rect = self.stats_rect;
        if (rect.width == 0) return;
        solidRect(.{ .x = rect.x - 1, .y = rect.y - 1, .width = rect.width + 2, .height = rect.height + 2 }, .{ 0.2, 0.23, 0.28 });
        solidRect(rect, .{ 0.04, 0.05, 0.07 });
        text.font(1);
        const title_cell = @min(10, (rect.width - 20) / 9);
        text.canvas(width * 8 / title_cell, height * 8 / title_cell);
        text.origin((rect.x + 10) / title_cell, (rect.y + 6) / title_cell);
        text.home();
        text.color3b(170, 200, 230);
        text.puts("Resources");
        const cell = @min(10, (rect.width - 20) / @as(f32, @floatFromInt(@max(1, layout.columns))));
        text.canvas(width * 8 / cell, height * 8 / cell);
        text.color3b(235, 235, 235);
        for (layout.lines[0..layout.count], 0..) |*line, i| {
            text.origin((rect.x + 10) / cell, (rect.y + 20 + @as(f32, @floatFromInt(i)) * 14) / cell);
            text.home();
            text.puts(std.mem.sliceTo(line, 0));
        }
    }

    fn drawProduction(self: *Renderer, layout: *const production.Layout, visible: bool, tab: inventory.Tab, width: f32, height: f32) void {
        const rect = self.production_rect;
        if (rect.width == 0) return;
        text.font(1);
        text.canvas(width * 8 / 12, height * 8 / 12);
        for ([_][:0]const u8{ "1P+R", "2U", "3S" }, self.production_tab_rects, 0..) |title, tab_rect, i| {
            if (@backingInt(tab) == i) solidRect(tab_rect, .{ 0.12, 0.22, 0.30 });
            text.origin((tab_rect.x + 4) / 12, (tab_rect.y + 4) / 12);
            text.home();
            text.color3b(170, 200, 230);
            text.puts(title);
        }
        const button = self.production_button_rect;
        solidRect(button, .{ 0.08, 0.12, 0.17 });
        text.origin((button.x + 4) / 12, (button.y + 5) / 12);
        text.home();
        text.color3b(235, 235, 235);
        text.puts(if (visible) "Hide" else "Show");
        text.canvas(width * 8 / 10, height * 8 / 10);
        for (layout.rows[0..layout.count], 0..) |*row, i| {
            const y = rect.y + 32 + @as(f32, @floatFromInt(i)) * 18;
            text.origin((rect.x + 10) / 10, y / 10);
            text.home();
            if (row.kind == .heading) text.color3b(170, 200, 230) else if (row.research) text.color3b(215, 185, 245) else text.color3b(235, 235, 235);
            const row_text = std.mem.sliceTo(&row.text, 0);
            if (row.counts) |counts| {
                text.putr(row_text, @intCast(counts.ready_begin));
                if (counts.ready == 0) text.color3b(145, 150, 158) else text.color3b(145, 215, 160);
                text.putr(row_text[counts.ready_begin..], @intCast(counts.building_begin - counts.ready_begin));
                if (counts.building == 0) text.color3b(145, 150, 158) else text.color3b(240, 195, 110);
                text.puts(row_text[counts.building_begin..]);
            } else text.puts(row_text);
            const bars_x = rect.x + rect.width - 206;
            for (row.bars[0..row.bar_count], 0..) |progress, j| {
                const bar: Rect = .{ .x = bars_x + @as(f32, @floatFromInt(j)) * 40, .y = y + 2, .width = 36, .height = 7 };
                solidRect(bar, .{ 0.16, 0.2, 0.24 });
                var fill = bar;
                fill.width *= progress;
                solidRect(fill, if (row.research) .{ 0.75, 0.4, 1 } else .{ 0.3, 0.85, 0.35 });
            }
            if (row.more > 0) {
                var buffer: [32]u8 = undefined;
                const value = std.mem.printSentinel(&buffer, "{d} more", .{row.more}, 0) catch unreachable;
                const more_cell = @min(10, 70 / @as(f32, @floatFromInt(value.len)));
                text.canvas(width * 8 / more_cell, height * 8 / more_cell);
                text.origin((bars_x + 124) / more_cell, y / more_cell);
                text.home();
                text.puts(value);
                text.canvas(width * 8 / 10, height * 8 / 10);
            }
        }
    }

    fn drawPlayerLabels(self: *Renderer, labels: @import("../replay/player_labels.zig").Labels, width: f32, height: f32) void {
        const rect = self.minimap_rect;
        if (rect.width < 8 or rect.height < 8) return;
        text.font(0);
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

fn playerStatsRect(width: f32, height: f32, info: Rect, minimap: Rect, chat: Rect) Rect {
    // Independent top-right panel. Hide rather than overlap the left panel
    // when the window is too narrow; reserve the bottom control-button row.
    const panel_width = @min(420, width - (info.x + info.width) - 24);
    const x = width - panel_width - 12;
    var bottom = height - 52;
    for ([_]Rect{ minimap, chat }) |other| {
        if (other.width > 0 and other.x < x + panel_width and other.x + other.width > x)
            bottom = @min(bottom, other.y - 12);
    }
    const space = @min(120, bottom - 12);
    if (panel_width < 240 or space < 40) return .{};
    return .{ .x = x, .y = 12, .width = panel_width, .height = space };
}

test "resource panel is top-right, avoids other UI and blocks world clicks" {
    const info: Rect = .{ .x = 12, .y = 12, .width = 500, .height = 230 };
    const mini: Rect = .{ .x = 12, .y = 528, .width = 180, .height = 180 };
    const stats = playerStatsRect(960, 720, info, mini, .{});
    try std.testing.expectEqual(@as(f32, 12), stats.y);
    try std.testing.expectEqual(@as(f32, 948), stats.x + stats.width);
    try std.testing.expect(stats.x >= info.x + info.width + 12);
    const small = playerStatsRect(800, 240, info, .{}, .{ .x = 500, .y = 120, .width = 280, .height = 100 });
    try std.testing.expect(small.y + small.height <= 108);
    try std.testing.expectEqual(@as(f32, 0), playerStatsRect(640, 720, info, .{}, .{}).width);
    try std.testing.expectEqual(@as(f32, 0), playerStatsRect(960, 100, info, .{}, .{}).width);
    var renderer: Renderer = .{ .info_rect = info, .stats_rect = stats };
    try std.testing.expect(renderer.blocksWorldClick(100, 100));
    try std.testing.expect(renderer.blocksWorldClick(stats.x + 20, stats.y + 20));
    try std.testing.expect(!renderer.blocksWorldClick(520, 100));
}

/// Maximum production area; drawing shrinks it to the number of visible rows.
fn productionRect(width: f32, height: f32, hud: Rect, minimap: Rect, chat: Rect) Rect {
    const panel_width = @min(@max(500, hud.width), width - 24);
    const y = hud.y + hud.height;
    if (panel_width < 320) return .{};
    var bottom = height - 12;
    if (minimap.width > 0) bottom = @min(bottom, minimap.y - 12);
    if (chat.width > 0 and chat.x < 12 + panel_width) bottom = @min(bottom, chat.y - 12);
    const available = bottom - y;
    if (available < 50) return .{};
    return .{ .x = 12, .y = y, .width = panel_width, .height = available };
}

test "production panel stays below HUD and above minimap/chat, hiding on tiny windows" {
    const hud: Rect = .{ .x = 12, .y = 12, .width = 448, .height = 48 };
    const mini: Rect = .{ .x = 12, .y = 528, .width = 180, .height = 180 };
    const panel = productionRect(960, 720, hud, mini, chatRect(960, 720, mini));
    try std.testing.expectEqual(@as(f32, 60), panel.y);
    try std.testing.expectEqual(chatRect(960, 720, mini).y - 12, panel.y + panel.height);
    const expanded = productionRect(960, 720, hud, mini, .{});
    try std.testing.expectEqual(mini.y - 12, expanded.y + expanded.height);
    try std.testing.expectEqual(@as(f32, 0), productionRect(300, 720, hud, .{}, .{}).width);
    try std.testing.expectEqual(@as(f32, 0), productionRect(960, 100, hud, .{}, .{}).width);
    const small_chat: Rect = .{ .x = 200, .y = 180, .width = 200, .height = 150 };
    const small = productionRect(420, 400, hud, .{}, small_chat);
    try std.testing.expect(small.y + small.height <= small_chat.y - 12);
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
