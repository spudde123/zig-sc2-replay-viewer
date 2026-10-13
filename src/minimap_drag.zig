const std = @import("std");
const Rect = @import("renderer.zig").Rect;

pub const Point = struct { x: f32, y: f32 };

/// GUI-owned drag state. Coordinates returned are normalized world coordinates,
/// with y increasing upwards. Only a press inside the minimap starts a drag.
pub const Drag = struct {
    active: bool = false,

    pub fn begin(self: *Drag, rect: Rect, x: f32, y: f32) ?Point {
        self.active = rect.contains(x, y);
        return self.update(rect, x, y);
    }

    pub fn update(self: *const Drag, rect: Rect, x: f32, y: f32) ?Point {
        if (!self.active or rect.width <= 0 or rect.height <= 0 or
            !std.math.isFinite(x) or !std.math.isFinite(y)) return null;
        return .{
            .x = std.math.clamp((x - rect.x) / rect.width, 0, 1),
            .y = 1 - std.math.clamp((y - rect.y) / rect.height, 0, 1),
        };
    }

    pub fn end(self: *Drag) void {
        self.active = false;
    }
};

test "minimap drag starts only inside, tracks movement, clamps edges and stops" {
    const rect: Rect = .{ .x = 10, .y = 20, .width = 100, .height = 200 };
    var drag: Drag = .{};
    try std.testing.expect(drag.begin(rect, 9, 30) == null);
    try std.testing.expect(drag.update(rect, 60, 120) == null);
    const start = drag.begin(rect, 60, 120).?;
    try std.testing.expectEqual(@as(f32, 0.5), start.x);
    try std.testing.expectEqual(@as(f32, 0.5), start.y);
    const moved = drag.update(rect, 35, 70).?;
    try std.testing.expectEqual(@as(f32, 0.25), moved.x);
    try std.testing.expectEqual(@as(f32, 0.75), moved.y);
    const outside = drag.update(rect, 500, -100).?;
    try std.testing.expectEqual(@as(f32, 1), outside.x);
    try std.testing.expectEqual(@as(f32, 1), outside.y);
    try std.testing.expect(drag.update(.{}, 10, 20) == null);
    drag.end();
    try std.testing.expect(drag.update(rect, 60, 120) == null);
}
