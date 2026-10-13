//! GUI-thread-only drawing. The camera, units and orders all come from the
//! displayed snapshot; never read the worker's ahead-of-image command state.
const std = @import("std");
const sokol = @import("sokol");
const gl = sokol.gl;
const text = sokol.debugtext;
const data = @import("replay_data.zig");
const camera = @import("camera_projection.zig");
const orders = @import("order_view.zig");
const Rect = camera.Rect;
const Point = camera.Point;

pub const View = struct {
    viewport: Rect,
    image_width: f32,
    image_height: f32,
    window_width: f32,
    window_height: f32,
    obstacles: []const Rect,
};

pub fn draw(scene: *const data.Scene, selected_tag: ?u64, markers: bool, view: View) Rect {
    const projection: camera.Projection = .{ .camera = scene.camera orelse return .{}, .width = view.image_width, .height = view.image_height };
    const viewport = view.viewport;
    if (viewport.width <= 0 or viewport.height <= 0) return .{};
    gl.scissorRectf(viewport.x, viewport.y, viewport.width, viewport.height, true);
    defer gl.scissorRectf(0, 0, view.window_width, view.window_height, true);
    if (markers) {
        var count: usize = 0;
        for (scene.units) |unit| {
            if (!unit.visible) continue;
            const point = projection.window(unit.position, viewport) orelse continue;
            if (!viewport.contains(point.x, point.y)) continue;
            line(.{ .x = point.x - 3, .y = point.y }, .{ .x = point.x + 3, .y = point.y }, .{ 0.2, 0.95, 1 }, 1);
            line(.{ .x = point.x, .y = point.y - 3 }, .{ .x = point.x, .y = point.y + 3 }, .{ 0.2, 0.95, 1 }, 1);
            count += 1;
            if (count == 4096) break; // stay within the default Sokol GL vertex budget
        }
    }
    const unit = scene.find(selected_tag orelse return .{}) orelse return .{};
    const footprint = camera.footprint(projection, viewport, unit) orelse return .{};
    // Keep selection by tag while panning offscreen, but don't show stale boxes.
    if (!viewport.contains(footprint.point.x, footprint.point.y)) return .{};
    ellipse(footprint.point, footprint.rx, footprint.ry, .{ 0.3, 1, 0.4 });
    const list = scene.ordersFor(unit);
    for (list[0..@min(list.len, orders.max_orders)]) |order| {
        const world_target = scene.targetPosition(order) orelse continue;
        const target = projection.window(world_target, viewport) orelse continue;
        const color: [3]f32 = .{ 1, 0.85, 0.2 };
        if (camera.clip(viewport, footprint.point, target)) |segment| arrow(segment.a, segment.b, color);
        if (viewport.contains(target.x, target.y)) ellipse(target, 4, 4, color);
    }
    const cell: f32 = 10;
    if (viewport.width < 160 or viewport.height < 140) return .{};
    const columns: usize = @intFromFloat(@floor((viewport.width - 36) / cell));
    const layout = orders.build(scene, unit, columns);
    const box_width = @as(f32, @floatFromInt(layout.columns)) * cell + 20;
    const box_height = @as(f32, @floatFromInt(layout.count)) * cell + 16;
    const rect = boxRect(footprint.point, footprint.rx, footprint.ry, box_width, box_height, viewport, view.obstacles) orelse return .{};
    solid(.{ .x = rect.x - 1, .y = rect.y - 1, .width = rect.width + 2, .height = rect.height + 2 }, .{ 0.2, 0.6, 0.3 });
    solid(rect, .{ 0.035, 0.06, 0.045 });
    text.font(1);
    text.canvas(view.window_width * 8 / cell, view.window_height * 8 / cell);
    for (layout.lines[0..layout.count], 0..) |*row, i| {
        text.origin((rect.x + 10) / cell, (rect.y + 8 + @as(f32, @floatFromInt(i)) * cell) / cell);
        text.home();
        text.color3b(if (i < 2) 150 else 235, if (i < 2) 240 else 235, if (i < 2) 170 else 235);
        text.puts(std.mem.sliceTo(row, 0));
    }
    return rect;
}

fn line(a: Point, b: Point, color: [3]f32, thickness: f32) void {
    const dx = b.x - a.x;
    const dy = b.y - a.y;
    const length = @sqrt(dx * dx + dy * dy);
    if (length < 0.001 or !std.math.isFinite(length)) return;
    const nx = -dy / length * thickness / 2;
    const ny = dx / length * thickness / 2;
    gl.disableTexture();
    gl.c3f(color[0], color[1], color[2]);
    gl.beginTriangles();
    gl.v2f(a.x + nx, a.y + ny);
    gl.v2f(a.x - nx, a.y - ny);
    gl.v2f(b.x + nx, b.y + ny);
    gl.v2f(b.x + nx, b.y + ny);
    gl.v2f(a.x - nx, a.y - ny);
    gl.v2f(b.x - nx, b.y - ny);
    gl.end();
}

fn arrow(a: Point, b: Point, color: [3]f32) void {
    line(a, b, color, 1.5);
    const dx = b.x - a.x;
    const dy = b.y - a.y;
    const length = @sqrt(dx * dx + dy * dy);
    if (length < 3) return;
    const ux = dx / length;
    const uy = dy / length;
    const size = @min(9, length / 2);
    gl.disableTexture();
    gl.c3f(color[0], color[1], color[2]);
    gl.beginTriangles();
    gl.v2f(b.x, b.y);
    gl.v2f(b.x - ux * size - uy * size * 0.45, b.y - uy * size + ux * size * 0.45);
    gl.v2f(b.x - ux * size + uy * size * 0.45, b.y - uy * size - ux * size * 0.45);
    gl.end();
}

fn ellipse(center: Point, rx: f32, ry: f32, color: [3]f32) void {
    var previous: Point = .{ .x = center.x + rx, .y = center.y };
    for (1..49) |i| {
        const angle = @as(f32, @floatFromInt(i)) * (2.0 * std.math.pi / 48.0);
        const next: Point = .{ .x = center.x + @cos(angle) * rx, .y = center.y + @sin(angle) * ry };
        line(previous, next, color, 1.5);
        previous = next;
    }
}

fn solid(rect: Rect, color: [3]f32) void {
    gl.disableTexture();
    gl.c3f(color[0], color[1], color[2]);
    gl.beginQuads();
    gl.v2f(rect.x, rect.y);
    gl.v2f(rect.x + rect.width, rect.y);
    gl.v2f(rect.x + rect.width, rect.y + rect.height);
    gl.v2f(rect.x, rect.y + rect.height);
    gl.end();
}

fn intersects(a: Rect, b: Rect) bool {
    return b.width > 0 and b.height > 0 and a.x < b.x + b.width + 3 and a.x + a.width + 3 > b.x and
        a.y < b.y + b.height + 3 and a.y + a.height + 3 > b.y;
}

/// Try above the unit first, then below/beside it. Never cover other GUI panels
/// or spill text into letterboxing. Hide the box if there is no usable space.
fn boxRect(point: Point, rx: f32, ry: f32, width: f32, height: f32, viewport: Rect, obstacles: []const Rect) ?Rect {
    if (width + 16 > viewport.width or height + 16 > viewport.height) return null;
    const candidates = [_]Point{
        .{ .x = point.x - width / 2, .y = point.y - ry - height - 12 },
        .{ .x = point.x - width / 2, .y = point.y + ry + 12 },
        .{ .x = point.x + rx + 12, .y = point.y - height / 2 },
        .{ .x = point.x - rx - width - 12, .y = point.y - height / 2 },
    };
    for (candidates) |candidate| {
        const rect: Rect = .{
            .x = std.math.clamp(candidate.x, viewport.x + 8, viewport.x + viewport.width - width - 8),
            .y = std.math.clamp(candidate.y, viewport.y + 8, viewport.y + viewport.height - height - 8),
            .width = width,
            .height = height,
        };
        var collision = false;
        for (obstacles) |obstacle| {
            if (intersects(rect, obstacle)) {
                collision = true;
                break;
            }
        }
        if (!collision) return rect;
    }
    return null;
}

test "order box avoids UI and letterboxing, or hides on small viewports" {
    const viewport: Rect = .{ .x = 120, .y = 0, .width = 960, .height = 720 };
    const hud: Rect = .{ .x = 120, .y = 0, .width = 400, .height = 80 };
    const box = boxRect(.{ .x = 300, .y = 90 }, 6, 6, 250, 80, viewport, &.{hud}).?;
    try std.testing.expect(!intersects(box, hud));
    try std.testing.expect(box.x >= viewport.x);
    try std.testing.expect(box.x + box.width <= viewport.x + viewport.width);
    try std.testing.expect(boxRect(.{ .x = 30, .y = 30 }, 6, 6, 200, 100, .{ .width = 100, .height = 100 }, &.{}) == null);
}
