//! Empirical SC2 4.10 observer RGB camera. See docs/camera-projection.md for
//! measurements and limitations. This is not an engine-provided view matrix.
const std = @import("std");
const data = @import("replay_data.zig");

pub const Rect = struct {
    x: f32 = 0,
    y: f32 = 0,
    width: f32 = 0,
    height: f32 = 0,
    pub fn contains(self: Rect, x: f32, y: f32) bool {
        return self.width > 0 and self.height > 0 and x >= self.x and y >= self.y and x < self.x + self.width and y < self.y + self.height;
    }
    pub fn fit(image_width: f32, image_height: f32, width: f32, height: f32) Rect {
        if (image_width <= 0 or image_height <= 0 or width <= 0 or height <= 0) return .{};
        const scale = @min(width / image_width, height / image_height);
        const w = image_width * scale;
        const h = image_height * scale;
        return .{ .x = (width - w) / 2, .y = (height - h) / 2, .width = w, .height = h };
    }
};
pub const Point = struct { x: f32, y: f32, depth: f32 = 0 };
pub const pitch: f32 = 56.0 * std.math.pi / 180.0;
pub const focal_height_ratio: f32 = 2.02079;

pub const Projection = struct {
    camera: data.CameraPose,
    width: f32,
    height: f32,

    pub fn project(self: Projection, world: data.Vec3) ?Point {
        const x = world.x - self.camera.target.x;
        const y = world.y - self.camera.target.y;
        const z = world.z - self.camera.target.z;
        const depth = self.camera.distance + y * @cos(pitch) - z * @sin(pitch);
        if (self.width <= 0 or self.height <= 0 or self.camera.distance <= 0 or depth < 0.1 or !std.math.isFinite(depth)) return null;
        const focal = self.height * focal_height_ratio;
        const px = self.width / 2 + focal * x / depth;
        const py = self.height / 2 - focal * (y * @sin(pitch) + z * @cos(pitch)) / depth;
        if (!std.math.isFinite(px) or !std.math.isFinite(py)) return null;
        return .{ .x = px, .y = py, .depth = depth };
    }

    pub fn window(self: Projection, world: data.Vec3, viewport: Rect) ?Point {
        const pixel = self.project(world) orelse return null;
        return .{ .x = viewport.x + pixel.x * viewport.width / self.width, .y = viewport.y + pixel.y * viewport.height / self.height, .depth = pixel.depth };
    }
};

pub const Footprint = struct { point: Point, rx: f32, ry: f32 };
pub fn footprint(projection: Projection, viewport: Rect, unit: *const data.Unit) ?Footprint {
    if (!unit.visible or !std.math.isFinite(unit.radius) or unit.radius <= 0) return null;
    const point = projection.window(unit.position, viewport) orelse return null;
    const edge = projection.window(.{ .x = unit.position.x + unit.radius, .y = unit.position.y, .z = unit.position.z }, viewport) orelse return null;
    return .{ .point = point, .rx = @max(6, @abs(edge.x - point.x)), .ry = @max(6, @abs(edge.x - point.x) * @sin(pitch)) };
}

/// Screen-space approximation, not mesh/depth-buffer picking. Smaller units
/// remain selectable among buildings; a deterministic tag tie-break avoids
/// depending on SC2's changing raw-unit iteration order.
pub fn pick(scene: *const data.Scene, viewport: Rect, image_width: f32, image_height: f32, x: f32, y: f32) ?u64 {
    if (!viewport.contains(x, y)) return null;
    const projection: Projection = .{ .camera = scene.camera orelse return null, .width = image_width, .height = image_height };
    var selected: ?u64 = null;
    var best: f32 = std.math.inf(f32);
    for (scene.units) |*unit| {
        const hit = footprint(projection, viewport, unit) orelse continue;
        // Extend a little above the ground anchor for the rendered model.
        const dx = (x - hit.point.x) / hit.rx;
        const dy = (y - (hit.point.y - hit.ry * 0.25)) / (hit.ry * 1.25);
        const score = dx * dx + dy * dy;
        if (score > 1 or !std.math.isFinite(score)) continue;
        if (score < best or (score == best and (selected == null or unit.tag < selected.?))) {
            selected = unit.tag;
            best = score;
        }
    }
    return selected;
}

pub const Segment = struct { a: Point, b: Point };
/// Liang-Barsky clipping. Offscreen targets produce a line to the viewport edge.
pub fn clip(rect: Rect, a: Point, b: Point) ?Segment {
    if (rect.width <= 0 or rect.height <= 0) return null;
    const dx = b.x - a.x;
    const dy = b.y - a.y;
    if (!std.math.isFinite(dx) or !std.math.isFinite(dy) or !std.math.isFinite(a.x) or !std.math.isFinite(a.y)) return null;
    const ps = [_]f32{ -dx, dx, -dy, dy };
    const qs = [_]f32{ a.x - rect.x, rect.x + rect.width - a.x, a.y - rect.y, rect.y + rect.height - a.y };
    var low: f32 = 0;
    var high: f32 = 1;
    for (ps, qs) |p, q| {
        if (p == 0) {
            if (q < 0) return null;
            continue;
        }
        const r = q / p;
        if (p < 0) low = @max(low, r) else high = @min(high, r);
        if (low > high) return null;
    }
    return .{ .a = .{ .x = a.x + dx * low, .y = a.y + dy * low }, .b = .{ .x = a.x + dx * high, .y = a.y + dy * high } };
}

test "projection centers target, handles zoom, height and behind-camera points" {
    var p: Projection = .{ .camera = .{ .target = .{ .x = 10, .y = 20, .z = 12 }, .distance = 40 }, .width = 640, .height = 480 };
    const center = p.project(p.camera.target).?;
    try std.testing.expectEqual(@as(f32, 320), center.x);
    try std.testing.expectEqual(@as(f32, 240), center.y);
    const right = p.project(.{ .x = 14, .y = 20, .z = 12 }).?;
    try std.testing.expectApproxEqAbs(@as(f32, 416.9979), right.x, 0.01);
    const raised = p.project(.{ .x = 10, .y = 20, .z = 16 }).?;
    try std.testing.expect(raised.y < center.y);
    p.camera.distance = 20;
    try std.testing.expectApproxEqAbs((right.x - 320) * 2, p.project(.{ .x = 14, .y = 20, .z = 12 }).?.x - 320, 0.01);
    try std.testing.expect(p.project(.{ .x = 10, .y = -100, .z = 12 }) == null);
    try std.testing.expect(p.project(.{ .x = std.math.nan(f32), .y = 20, .z = 12 }) == null);
}

test "letterboxed picking respects hidden units, stable tags and viewport borders" {
    const viewport = Rect.fit(640, 480, 1200, 720);
    try std.testing.expectEqual(@as(f32, 120), viewport.x);
    var units = [_]data.Unit{
        .{ .tag = 10, .type_id = 45, .owner = 1, .position = .{}, .radius = 0.375, .visible = true, .flying = false, .order_start = 0, .order_count = 0 },
        .{ .tag = 20, .type_id = 18, .owner = 1, .position = .{ .x = 4 }, .radius = 2.75, .visible = true, .flying = false, .order_start = 0, .order_count = 0 },
    };
    var scene: data.Scene = .{ .camera = .{ .target = .{}, .distance = 40 }, .units = &units };
    try std.testing.expectEqual(@as(?u64, 10), pick(&scene, viewport, 640, 480, 600, 360));
    try std.testing.expect(pick(&scene, viewport, 640, 480, 50, 360) == null);
    units[0].visible = false;
    try std.testing.expect(pick(&scene, viewport, 640, 480, 600, 360) == null);
    scene.camera = null;
    try std.testing.expect(pick(&scene, viewport, 640, 480, 750, 360) == null);
}

test "line clipping handles offscreen targets, parallel and degenerate lines" {
    const rect: Rect = .{ .x = 10, .y = 20, .width = 100, .height = 80 };
    const line = clip(rect, .{ .x = 50, .y = 50 }, .{ .x = 200, .y = 50 }).?;
    try std.testing.expectEqual(@as(f32, 110), line.b.x);
    try std.testing.expect(clip(rect, .{ .x = 0, .y = 0 }, .{ .x = 200, .y = 0 }) == null);
    try std.testing.expect(clip(rect, .{ .x = 50, .y = 50 }, .{ .x = 50, .y = 50 }) != null);
}
