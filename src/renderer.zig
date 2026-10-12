const std = @import("std");
const sokol = @import("sokol");
const gfx = sokol.gfx;
const gl = sokol.gl;
const text = sokol.debugtext;
const formatGameTime = @import("playback.zig").formatGameTime;
const Image = @import("image.zig").Image;
const Frame = @import("image.zig").Frame;

pub const Rect = struct {
    x: f32 = 0,
    y: f32 = 0,
    width: f32 = 0,
    height: f32 = 0,

    pub fn contains(self: Rect, x: f32, y: f32) bool {
        return self.width > 0 and self.height > 0 and x >= self.x and y >= self.y and x < self.x + self.width and y < self.y + self.height;
    }
};

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
        return std.mem.printSentinel(buffer, "{s} / {s} | {d}x | {s}\nLoop {d} / {d}\nSpace pause | Up/Down speed | WASD camera", .{ current, duration, self.speed, @tagName(self.state), game_loop, self.duration_loops }, 0);
    }
};

pub const Renderer = struct {
    map: Texture = .{},
    minimap: Texture = .{},
    sampler: gfx.Sampler = .{},
    minimap_rect: Rect = .{},

    pub fn init() Renderer {
        gfx.setup(.{ .environment = sokol.glue.environment(), .logger = .{ .func = sokol.log.func } });
        gl.setup(.{ .logger = .{ .func = sokol.log.func } });
        text.setup(.{
            .fonts = blk: {
                var fonts: [8]text.FontDesc = @splat(.{});
                fonts[0] = text.fontOric();
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

    pub fn draw(self: *Renderer, frame: ?Frame, hud: Hud) void {
        const width: f32 = @floatFromInt(sokol.app.width());
        const height: f32 = @floatFromInt(sokol.app.height());
        gl.defaults();
        gl.matrixModeProjection();
        gl.ortho(0, width, height, 0, -1, 1);
        self.minimap_rect = .{};
        if (frame) |f| {
            self.map.upload(f.map);
            const scale = @min(width / @as(f32, @floatFromInt(f.map.width)), height / @as(f32, @floatFromInt(f.map.height)));
            const w = @as(f32, @floatFromInt(f.map.width)) * scale;
            const h = @as(f32, @floatFromInt(f.map.height)) * scale;
            self.quad(self.map.view, .{ .x = (width - w) / 2, .y = (height - h) / 2, .width = w, .height = h });
            if (f.minimap) |m| {
                self.minimap.upload(m);
                const side = @min(180, @min(width, height) * 0.28);
                self.minimap_rect = .{ .x = 12, .y = height - side - 12, .width = side, .height = side };
                solidRect(.{ .x = self.minimap_rect.x - 2, .y = self.minimap_rect.y - 2, .width = side + 4, .height = side + 4 }, .{ 0.2, 0.23, 0.28 });
                self.quad(self.minimap.view, self.minimap_rect);
            }
        }
        var hud_buffer: [256]u8 = undefined;
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
        solidRect(.{ .x = 12, .y = 12, .width = hud_right - 12, .height = hud_bottom - 12 }, .{ 0, 0, 0 });
        text.canvas(width * 8 / cell_size, height * 8 / cell_size);
        text.origin(20 / cell_size, 20 / cell_size);
        text.home();
        text.color3b(255, 255, 255);
        text.puts(label);
        if (self.minimap_rect.width > 0) self.drawPlayerLabels(hud.labels, width, height);
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

test "HUD shows frame time, duration, speed, state and loop counts" {
    var buffer: [256]u8 = undefined;
    const hud: Hud = .{ .duration_loops = 14884, .speed = 0.25, .state = .paused };
    try std.testing.expectEqualStrings(
        "01:00 / 11:04 | 0.25x | paused\nLoop 1344 / 14884\nSpace pause | Up/Down speed | WASD camera",
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
