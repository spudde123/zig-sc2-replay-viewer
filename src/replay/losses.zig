//! Exact recent tracker deaths. Cumulative resource losses come from player stats.
const std = @import("std");
const data = @import("replay_data.zig");
pub const Name = @FieldType(data.Product, "name");
pub const window_loops = 336; // 15 game seconds at 22.4 loops/second.
pub const Death = struct { game_loop: u32, owner: u32, name: Name };
pub const Group = struct { owner: u32, name: Name, recent: usize = 0 };
pub const Snapshot = struct {
    available: bool = false,
    groups: []Group = &.{},

    pub fn deinit(self: Snapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.groups);
    }
};

/// Query by displayed loop, never wall time. Future deaths are never exposed.
/// Window is (loop - 336, loop], including loop zero at the start of the game.
pub fn snapshot(allocator: std.mem.Allocator, deaths: []const Death, loop: u32) !Snapshot {
    var groups: std.ArrayList(Group) = .empty;
    defer groups.deinit(allocator);
    for (deaths) |death| {
        if (death.game_loop > loop) break;
        if (loop - death.game_loop >= window_loops) continue;
        var index: usize = 0;
        while (index < groups.items.len) : (index += 1) {
            const group = groups.items[index];
            if (group.owner == death.owner and std.mem.eql(u8, &group.name, &death.name)) break;
        }
        if (index == groups.items.len) try groups.append(allocator, .{ .owner = death.owner, .name = death.name });
        groups.items[index].recent += 1;
    }
    std.mem.sort(Group, groups.items, {}, struct {
        fn less(_: void, a: Group, b: Group) bool {
            if (a.owner != b.owner) return a.owner < b.owner;
            return std.mem.order(u8, &a.name, &b.name) == .lt;
        }
    }.less);
    return .{ .available = true, .groups = try groups.toOwnedSlice(allocator) };
}

test "loss snapshots respect future events, exact window boundaries and repeated queries" {
    var name: Name = @splat(0);
    @memcpy(name[0..6], "Marine");
    const deaths = [_]Death{
        .{ .game_loop = 0, .owner = 3, .name = name },
        .{ .game_loop = 1, .owner = 3, .name = name },
        .{ .game_loop = 336, .owner = 7, .name = name },
        .{ .game_loop = 337, .owner = 3, .name = name },
    };
    const a = try snapshot(std.testing.allocator, &deaths, 336);
    defer a.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), a.groups[0].recent);
    try std.testing.expectEqual(@as(u32, 7), a.groups[1].owner);
    const b = try snapshot(std.testing.allocator, &deaths, 0);
    defer b.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), b.groups[0].recent);
    const c = try snapshot(std.testing.allocator, &deaths, 1000);
    defer c.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), c.groups.len);
    try std.testing.expect(c.available); // Known empty is distinct from unavailable.
}
