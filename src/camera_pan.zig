const std = @import("std");
const Keycode = @import("sokol").app.Keycode;
const Camera = @import("replay_worker.zig").Camera;

/// GUI-owned held-key state; movement is integrated each display frame.
pub const Pan = struct {
    keys: [4]bool = @splat(false), // W, A, S, D

    pub fn setKey(self: *Pan, key: Keycode, pressed: bool) bool {
        const index: usize = switch (key) {
            .W => 0,
            .A => 1,
            .S => 2,
            .D => 3,
            else => return false,
        };
        self.keys[index] = pressed;
        return true;
    }

    pub fn clear(self: *Pan) void {
        self.keys = @splat(false);
    }

    pub fn apply(self: Pan, camera: *Camera, seconds: f64, width: f32, height: f32) bool {
        if (!std.math.isFinite(seconds) or seconds <= 0) return false;
        const dx: f32 = @as(f32, @floatFromInt(@intFromBool(self.keys[3]))) - @as(f32, @floatFromInt(@intFromBool(self.keys[1])));
        const dy: f32 = @as(f32, @floatFromInt(@intFromBool(self.keys[0]))) - @as(f32, @floatFromInt(@intFromBool(self.keys[2])));
        const length = @sqrt(dx * dx + dy * dy);
        if (length == 0) return false;
        // Fixed world-space speed, independent of replay speed and keyboard repeat.
        // Limit long display stalls to avoid sudden camera jumps on resuming.
        const distance: f32 = @as(f32, @floatCast(@min(seconds, 0.05))) * 48;
        const x = std.math.clamp(camera.x + dx / length * distance, 0, width);
        const y = std.math.clamp(camera.y + dy / length * distance, 0, height);
        const changed = x != camera.x or y != camera.y;
        camera.x = x;
        camera.y = y;
        return changed;
    }
};

test "held keys pan continuously with normalized diagonals and preserve zoom" {
    var pan: Pan = .{};
    var straight: Camera = .{ .x = 100, .y = 100, .distance = 60 };
    try std.testing.expect(pan.setKey(.W, true));
    try std.testing.expect(pan.apply(&straight, 1.0 / 60.0, 256, 256));
    try std.testing.expectApproxEqAbs(@as(f32, 100.8), straight.y, 0.001);
    var diagonal: Camera = .{ .x = 100, .y = 100, .distance = 60 };
    _ = pan.setKey(.D, true);
    _ = pan.apply(&diagonal, 1.0 / 60.0, 256, 256);
    const dx = diagonal.x - 100;
    const dy = diagonal.y - 100;
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), @sqrt(dx * dx + dy * dy), 0.001);
    try std.testing.expectApproxEqAbs(dx, dy, 0.001);
    try std.testing.expectEqual(@as(f32, 60), diagonal.distance);
    _ = pan.setKey(.S, true);
    _ = pan.setKey(.A, true);
    try std.testing.expect(!pan.apply(&diagonal, 0.02, 256, 256));
    _ = pan.setKey(.D, false);
    try std.testing.expect(pan.apply(&diagonal, 0.02, 256, 256));
    pan.clear();
    try std.testing.expect(!pan.apply(&diagonal, 0.02, 256, 256));
}

test "panning is frame-rate independent, bounded and limits stalls" {
    var pan: Pan = .{};
    _ = pan.setKey(.D, true);
    var a: Camera = .{ .x = 0, .y = 0 };
    var b = a;
    for (0..60) |_| _ = pan.apply(&a, 1.0 / 60.0, 256, 256);
    for (0..120) |_| _ = pan.apply(&b, 1.0 / 120.0, 256, 256);
    try std.testing.expectApproxEqAbs(@as(f32, 48), a.x, 0.001);
    try std.testing.expectApproxEqAbs(a.x, b.x, 0.001);
    a.x = 255;
    _ = pan.apply(&a, 0.05, 256, 256);
    try std.testing.expectEqual(@as(f32, 256), a.x);
    try std.testing.expect(!pan.apply(&a, 0.05, 256, 256));
    b.x = 0;
    _ = pan.apply(&b, 10, 256, 256);
    try std.testing.expectApproxEqAbs(@as(f32, 2.4), b.x, 0.001);
}
