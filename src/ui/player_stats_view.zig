//! Bounded formatting of the most recent preceding replay-stat samples.
const std = @import("std");
const data = @import("../replay/replay_data.zig");
pub const Layout = struct {
    lines: [33][96:0]u8 = @splat(@splat(0)),
    count: usize = 0,
    columns: usize = 0,
    fn add(self: *Layout, value: []const u8) void {
        const n = @min(value.len, self.lines[0].len);
        @memcpy(self.lines[self.count][0..n], value[0..n]);
        for (self.lines[self.count][0..n]) |*c| if (c.* < 32 or c.* > 126) {
            c.* = '?';
        };
        self.columns = @max(self.columns, n);
        self.count += 1;
    }
};

pub fn build(players: *const data.Players, stats: data.PlayerStats, rows: usize) Layout {
    var layout: Layout = .{};
    const limit = @min(rows, layout.lines.len);
    if (limit == 0) return layout;
    if (players.count == 0) {
        layout.add("Waiting for player metadata");
        return layout;
    }
    var shown: usize = 0;
    for (players.items[0..players.count], 0..) |*player, i| {
        const reserve: usize = if (i + 1 < players.count) 1 else 0;
        if (layout.count + 2 + reserve > limit) break;
        var buffer: [256]u8 = undefined;
        var fallback: [24]u8 = undefined;
        const name = players.name(player.id) orelse std.fmt.bufPrint(&fallback, "Player {d}", .{player.id}) catch unreachable;
        const sample = if (player.id < stats.items.len) stats.items[player.id] else null;
        if (sample) |s| {
            layout.add(name);
            var used: [24]u8 = undefined;
            var cap: [24]u8 = undefined;
            const used_text = food(&used, s.food_used);
            const cap_text = food(&cap, s.food_cap);
            layout.add(std.fmt.bufPrint(&buffer, "M: {d}  V: {d}  Supply: {s} / {s}", .{ s.minerals, s.vespene, used_text, cap_text }) catch unreachable);
        } else {
            layout.add(name);
            layout.add(if (stats.available) "Waiting for first stat sample" else "Replay statistics unavailable");
        }
        shown += 1;
    }
    if (shown < players.count and layout.count < limit) {
        var buffer: [64]u8 = undefined;
        layout.add(std.fmt.bufPrint(&buffer, "{d} players not shown", .{players.count - shown}) catch unreachable);
    }
    return layout;
}
fn food(buffer: []u8, value: f32) []const u8 {
    return if (@floor(value) == value) std.fmt.bufPrint(buffer, "{d:.0}", .{value}) catch unreachable else std.fmt.bufPrint(buffer, "{d:.1}", .{value}) catch unreachable;
}

test "stats formatting shows player names, fractional supply, missing data and bounded rows" {
    var players: data.Players = .{};
    players.add(1, "Alice");
    players.add(2, "Bob");
    var stats: data.PlayerStats = .{ .available = true };
    stats.items[1] = .{ .game_loop = 160, .minerals = 123, .vespene = 55, .food_used = 13.5, .food_cap = 200 };
    const layout = build(&players, stats, 10);
    try std.testing.expectEqualStrings("Alice", std.mem.sliceTo(&layout.lines[0], 0));
    try std.testing.expectEqualStrings("M: 123  V: 55  Supply: 13.5 / 200", std.mem.sliceTo(&layout.lines[1], 0));
    try std.testing.expectEqualStrings("Waiting for first stat sample", std.mem.sliceTo(&layout.lines[3], 0));
    const unavailable = build(&players, .{}, 10);
    try std.testing.expectEqualStrings("Replay statistics unavailable", std.mem.sliceTo(&unavailable.lines[1], 0));
    try std.testing.expectEqual(@as(usize, 0), build(&players, stats, 0).count);
    try std.testing.expectEqualStrings("2 players not shown", std.mem.sliceTo(&build(&players, stats, 1).lines[0], 0));
}
