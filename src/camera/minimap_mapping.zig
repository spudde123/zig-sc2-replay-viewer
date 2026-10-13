const std = @import("std");
const sc2 = @import("zig-sc2");

pub const Point = struct { x: f32, y: f32 };

/// SC2's square RGB minimap fits the playable area, preserving aspect ratio.
/// Both normalized image coordinates and world coordinates have upward Y.
pub const Mapping = struct {
    x: f32 = 0,
    y: f32 = 0,
    width: f32 = 256,
    height: f32 = 256,

    pub fn fromPlayable(area: ?sc2.sc2p.RectangleI, map_width: f32, map_height: f32) Mapping {
        const fallback: Mapping = .{ .width = map_width, .height = map_height };
        const bounds = area orelse return fallback;
        const lo = bounds.p0 orelse return fallback;
        const hi = bounds.p1 orelse return fallback;
        const x: f32 = @floatFromInt(lo.x orelse return fallback);
        const y: f32 = @floatFromInt(lo.y orelse return fallback);
        const right: f32 = @floatFromInt(hi.x orelse return fallback);
        const top: f32 = @floatFromInt(hi.y orelse return fallback);
        if (x < 0 or y < 0 or right > map_width or top > map_height or right <= x or top <= y) return fallback;
        return .{ .x = x, .y = y, .width = right - x, .height = top - y };
    }

    pub fn toWorld(self: Mapping, point: Point) Point {
        const side = @max(self.width, self.height);
        return .{
            .x = self.x + std.math.clamp(point.x * side - (side - self.width) / 2, 0, self.width),
            .y = self.y + std.math.clamp(point.y * side - (side - self.height) / 2, 0, self.height),
        };
    }

    pub fn toImage(self: Mapping, point: Point) Point {
        const side = @max(self.width, self.height);
        return .{
            .x = std.math.clamp((point.x - self.x + (side - self.width) / 2) / side, 0, 1),
            .y = std.math.clamp((point.y - self.y + (side - self.height) / 2) / side, 0, 1),
        };
    }
};

test "Torches minimap base click uses cropped playable area, not full terrain dimensions" {
    const map = Mapping.fromPlayable(.{ .p0 = .{ .x = 14, .y = 32 }, .p1 = .{ .x = 142, .y = 176 } }, 160, 208);
    const pixel = map.toImage(.{ .x = 124.5, .y = 159.5 });
    try std.testing.expectApproxEqAbs(@as(f32, 105.33333), pixel.x * 128, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 14.66667), (1 - pixel.y) * 128, 0.001);
    const world = map.toWorld(pixel);
    try std.testing.expectApproxEqAbs(@as(f32, 124.5), world.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 159.5), world.y, 0.001);
    // The old mapping put this click outside playable terrain, causing SC2 to
    // clamp its camera independently of the pose used by the local projection.
    try std.testing.expect(pixel.y * 208 > 176);
}

test "minimap mapping handles both padding axes, square maps and edge clamping" {
    const wide: Mapping = .{ .x = 10, .y = 20, .width = 200, .height = 100 };
    const image = wide.toImage(.{ .x = 60, .y = 45 });
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), image.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.375), image.y, 0.001);
    const world = wide.toWorld(image);
    try std.testing.expectApproxEqAbs(@as(f32, 60), world.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 45), world.y, 0.001);
    try std.testing.expectEqual(Point{ .x = 10, .y = 20 }, wide.toWorld(.{ .x = -1, .y = -1 }));
    try std.testing.expectEqual(Point{ .x = 210, .y = 120 }, wide.toWorld(.{ .x = 2, .y = 2 }));
    const square: Mapping = .{};
    try std.testing.expectEqual(Point{ .x = 128, .y = 64 }, square.toWorld(.{ .x = 0.5, .y = 0.25 }));
}

test "missing and invalid playable rectangles fall back to full map bounds" {
    const expected: Mapping = .{ .width = 160, .height = 208 };
    try std.testing.expectEqual(expected, Mapping.fromPlayable(null, 160, 208));
    try std.testing.expectEqual(expected, Mapping.fromPlayable(.{}, 160, 208));
    try std.testing.expectEqual(expected, Mapping.fromPlayable(.{ .p0 = .{ .x = 142, .y = 176 }, .p1 = .{ .x = 14, .y = 32 } }, 160, 208));
}
