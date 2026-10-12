const std = @import("std");

pub const speeds = [_]f64{ 0.25, 0.5, 1, 2, 4, 8, 16 };

pub fn formatGameTime(buffer: []u8, game_loop: u32) std.mem.PrintError![:0]const u8 {
    // 22.4 loops/second = 112/5; integer math avoids rounding at second boundaries.
    const seconds = @as(u64, game_loop) * 5 / 112;
    return std.mem.printSentinel(buffer, "{d:0>2}:{d:0>2}", .{ seconds / 60, seconds % 60 }, 0);
}
pub const Playback = struct {
    speed_index: usize = 2,
    paused: bool = false,
    budget: f64 = 0,

    pub fn speed(self: Playback) f64 {
        return speeds[self.speed_index];
    }

    pub fn setPaused(self: *Playback, paused: bool) void {
        self.paused = paused;
        self.budget = 0;
    }

    pub fn changeSpeed(self: *Playback, faster: bool) void {
        if (faster) {
            self.speed_index = @min(self.speed_index + 1, speeds.len - 1);
        } else self.speed_index -|= 1;
        self.budget = 0;
    }

    /// Clamp elapsed time/debt: a slow renderer never creates an unbounded backlog.
    pub fn due(self: *Playback, elapsed: f64) u32 {
        if (self.paused) return 0;
        self.budget = @min(32, self.budget + @max(0, @min(elapsed, 0.25)) * 22.4 * self.speed());
        const count: u32 = @intFromFloat(@floor(self.budget));
        self.budget -= @floatFromInt(count);
        return count;
    }
};

test "game time floors partial seconds and keeps total minutes beyond an hour" {
    var buffer: [16]u8 = undefined;
    const cases = .{
        .{ @as(u32, 0), "00:00" },
        .{ @as(u32, 22), "00:00" },
        .{ @as(u32, 23), "00:01" },
        .{ @as(u32, 1343), "00:59" },
        .{ @as(u32, 1344), "01:00" },
        .{ @as(u32, 14884), "11:04" },
        .{ @as(u32, 161280), "120:00" },
        .{ std.math.maxInt(u32), "3195660:11" },
    };
    inline for (cases) |case| try std.testing.expectEqualStrings(case[1], try formatGameTime(&buffer, case[0]));
    var short_buffer: [5]u8 = undefined;
    try std.testing.expectError(error.NoSpaceLeft, formatGameTime(&short_buffer, 0));
}

test "fractional timing, pause, speed limits and bounded backlog" {
    var p: Playback = .{};
    var loops: u32 = 0;
    for (0..100) |_| loops += p.due(0.01);
    try std.testing.expectEqual(@as(u32, 22), loops);
    p.setPaused(true);
    try std.testing.expectEqual(@as(u32, 0), p.due(100));
    p.setPaused(false);
    try std.testing.expectEqual(@as(u32, 0), p.due(0));
    for (0..100) |_| p.changeSpeed(true);
    try std.testing.expectEqual(@as(f64, 16), p.speed());
    try std.testing.expectEqual(@as(u32, 32), p.due(100));
    for (0..100) |_| p.changeSpeed(false);
    try std.testing.expectEqual(@as(f64, 0.25), p.speed());
}
