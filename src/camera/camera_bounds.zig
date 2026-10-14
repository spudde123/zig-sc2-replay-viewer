const std = @import("std");
const minimap = @import("minimap_mapping.zig");

/// Conservative observer-camera limits, not engine-reported camera bounds.
/// A 12-world-unit inset avoided silent edge clamps on Torches/Pylon at
/// distances 10, 40 and 100; an 8-unit inset still clamped on some edges.
pub const Bounds = struct {
    min_x: f32 = 12,
    min_y: f32 = 12,
    max_x: f32 = 244,
    max_y: f32 = 244,

    pub fn fromPlayable(area: minimap.Mapping) Bounds {
        // Very small maps collapse an axis to its centre rather than invert it.
        const dx = @min(12, area.width / 2);
        const dy = @min(12, area.height / 2);
        return .{ .min_x = area.x + dx, .min_y = area.y + dy, .max_x = area.x + area.width - dx, .max_y = area.y + area.height - dy };
    }

    pub fn clamp(self: Bounds, x: f32, y: f32) minimap.Point {
        return .{ .x = std.math.clamp(x, self.min_x, self.max_x), .y = std.math.clamp(y, self.min_y, self.max_y) };
    }
};

test "camera limits inset the playable rectangle rather than the full map" {
    const bounds = Bounds.fromPlayable(.{ .x = 14, .y = 32, .width = 128, .height = 144 });
    try std.testing.expectEqual(minimap.Point{ .x = 26, .y = 44 }, bounds.clamp(0, 0));
    try std.testing.expectEqual(minimap.Point{ .x = 130, .y = 164 }, bounds.clamp(160, 208));
    try std.testing.expectEqual(minimap.Point{ .x = 124.5, .y = 159.5 }, bounds.clamp(124.5, 159.5));
}

test "camera limits stay ordered for maps smaller than the safety margin" {
    const bounds = Bounds.fromPlayable(.{ .x = 10, .y = 20, .width = 10, .height = 24 });
    try std.testing.expectEqual(minimap.Point{ .x = 15, .y = 32 }, bounds.clamp(-100, 100));
}
