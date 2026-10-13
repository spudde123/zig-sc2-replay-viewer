//! Bounded display formatting for one selected unit; no SC2/graphics dependency.
const std = @import("std");
const data = @import("replay_data.zig");
pub const max_orders = 1;
pub const max_columns = 64;
pub const max_rows = 5;
pub const Layout = struct {
    lines: [max_rows][max_columns:0]u8 = @splat(@splat(0)),
    count: usize = 0,
    columns: usize = 0,

    fn add(self: *Layout, limit: usize, comptime format: []const u8, args: anytype) void {
        if (self.count == max_rows) return;
        var buffer: [256]u8 = undefined;
        const value = std.fmt.bufPrint(&buffer, format, args) catch unreachable;
        const n = @min(value.len, limit);
        @memcpy(self.lines[self.count][0..n], value[0..n]);
        if (value.len > n and n >= 3) @memcpy(self.lines[self.count][n - 3 .. n], "...");
        self.columns = @max(self.columns, n);
        self.count += 1;
    }
};

pub fn build(scene: *const data.Scene, unit: *const data.Unit, columns: usize) Layout {
    var result: Layout = .{};
    const limit = std.math.clamp(columns, 1, max_columns);
    result.add(limit, "{s} | owner {d}", .{ std.mem.sliceTo(&unit.name, 0), unit.owner });
    result.add(limit, "Tag {d}", .{unit.tag});
    const orders = scene.ordersFor(unit);
    if (orders.len == 0) result.add(limit, "No orders reported", .{});
    for (orders[0..@min(orders.len, max_orders)], 0..) |order, i| {
        if (std.math.isFinite(order.progress) and order.progress > 0) {
            result.add(limit, "{d}. {s} ({d}) {d:.0}%", .{ i + 1, std.mem.sliceTo(&order.name, 0), order.ability_id, std.math.clamp(order.progress, 0, 1) * 100 });
        } else result.add(limit, "{d}. {s} ({d})", .{ i + 1, std.mem.sliceTo(&order.name, 0), order.ability_id });
        switch (order.target) {
            .none => result.add(limit, "   No spatial target", .{}),
            .position => |p| result.add(limit, "   -> ({d:.1}, {d:.1}){s}", .{ p.x, p.y, if (p.z == null) " [height unknown]" else "" }),
            .unit => |tag| {
                if (scene.find(tag)) |target| {
                    result.add(limit, "   -> {s} #{d}{s}", .{ std.mem.sliceTo(&target.name, 0), tag, if (target.visible) "" else " [not visible]" });
                } else result.add(limit, "   -> #{d} [unavailable]", .{tag});
            },
        }
    }
    if (orders.len > max_orders) result.add(limit, "... {d} more orders", .{orders.len - max_orders});
    return result;
}

test "order text bounds queue size, missing targets, long text and no orders" {
    var orders: [20]data.Order = @splat(.{ .ability_id = 16, .progress = 0, .target = .{ .unit = 999 } });
    var units = [_]data.Unit{.{ .tag = 1, .type_id = 45, .owner = 1, .position = .{}, .radius = 0.375, .visible = true, .flying = false, .order_start = 0, .order_count = orders.len }};
    const scene: data.Scene = .{ .units = &units, .orders = &orders };
    const layout = build(&scene, &units[0], 20);
    try std.testing.expectEqual(max_rows, layout.count);
    for (layout.lines[0..layout.count]) |line| try std.testing.expect(std.mem.sliceTo(&line, 0).len <= 20);
    try std.testing.expectEqualStrings("... 19 more orders", std.mem.sliceTo(&layout.lines[4], 0));
    // Later orders are retained in the snapshot but must not appear in the box.
    orders[1].ability_id = 9999;
    const first_only = build(&scene, &units[0], 64);
    try std.testing.expect(std.mem.indexOf(u8, std.mem.sliceTo(&first_only.lines[2], 0), "9999") == null);
    try std.testing.expect(scene.targetPosition(orders[0]) == null);
    units[0].order_count = 0;
    const idle = build(&scene, &units[0], 64);
    try std.testing.expectEqualStrings("No orders reported", std.mem.sliceTo(&idle.lines[2], 0));
}
