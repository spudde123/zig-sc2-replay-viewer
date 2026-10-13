//! Bounded display formatting for one selected unit; no SC2/graphics dependency.
const std = @import("std");
const data = @import("replay_data.zig");
pub const max_orders = 1;
pub const max_columns = 64;
pub const max_rows = 11;
pub const Bar = struct {
    kind: enum { health, shield, energy },
    fraction: f32,
};
pub const Layout = struct {
    lines: [max_rows][max_columns:0]u8 = @splat(@splat(0)),
    bars: [max_rows]?Bar = @splat(null),
    count: usize = 0,
    columns: usize = 0,

    /// Bar rows reserve a second character cell below the numeric label.
    pub fn heightCells(self: *const Layout) usize {
        var cells = self.count;
        for (self.bars[0..self.count]) |bar| if (bar != null) {
            cells += 1;
        };
        return cells;
    }

    fn addBar(self: *Layout, limit: usize, kind: @FieldType(Bar, "kind"), label: []const u8, current: f32, maximum: f32) void {
        if (self.count == max_rows or !std.math.isFinite(current) or !std.math.isFinite(maximum) or maximum <= 0) return;
        const row = self.count;
        self.add(limit, "{s} {d:.0} / {d:.0}", .{ label, current, maximum });
        self.bars[row] = .{ .kind = kind, .fraction = std.math.clamp(current / maximum, 0, 1) };
    }

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
    result.addBar(limit, .health, "HP", unit.health, unit.health_max);
    result.addBar(limit, .shield, "Shields", unit.shield, unit.shield_max);
    result.addBar(limit, .energy, "Energy", unit.energy, unit.energy_max);
    if (unit.mineral_contents > 0) result.add(limit, "Minerals: {d}", .{unit.mineral_contents});
    if (unit.vespene_contents > 0) result.add(limit, "Vespene: {d}", .{unit.vespene_contents});
    if (unit.ideal_harvesters > 0) result.add(limit, "Harvesters: {d} / {d}", .{ unit.assigned_harvesters, unit.ideal_harvesters });
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

test "unit details show ordered bars, resource contents and integer harvesters" {
    var list = [_]data.Order{ .{ .ability_id = 16, .progress = 0, .target = .none }, .{ .ability_id = 9999, .progress = 0, .target = .none } };
    var units = [_]data.Unit{.{
        .tag = 1,
        .type_id = 45,
        .owner = 1,
        .position = .{},
        .radius = 1,
        .visible = true,
        .flying = false,
        .order_start = 0,
        .order_count = 2,
        .health = 75,
        .health_max = 100,
        .shield = 0,
        .shield_max = 50,
        .energy = 25,
        .energy_max = 200,
        .mineral_contents = 1500,
        .vespene_contents = 2250,
        .assigned_harvesters = 0,
        .ideal_harvesters = 3,
    }};
    const scene: data.Scene = .{ .units = &units, .orders = &list };
    const layout = build(&scene, &units[0], 64);
    try std.testing.expectEqual(max_rows, layout.count);
    try std.testing.expectEqual(@as(usize, 14), layout.heightCells());
    try std.testing.expectEqualStrings("HP 75 / 100", std.mem.sliceTo(&layout.lines[2], 0));
    try std.testing.expectEqualStrings("Shields 0 / 50", std.mem.sliceTo(&layout.lines[3], 0));
    try std.testing.expectEqualStrings("Energy 25 / 200", std.mem.sliceTo(&layout.lines[4], 0));
    try std.testing.expectEqual(@as(f32, 0.75), layout.bars[2].?.fraction);
    try std.testing.expectEqual(@as(f32, 0), layout.bars[3].?.fraction);
    try std.testing.expectEqual(@as(f32, 0.125), layout.bars[4].?.fraction);
    try std.testing.expectEqualStrings("Minerals: 1500", std.mem.sliceTo(&layout.lines[5], 0));
    try std.testing.expectEqualStrings("Vespene: 2250", std.mem.sliceTo(&layout.lines[6], 0));
    try std.testing.expectEqualStrings("Harvesters: 0 / 3", std.mem.sliceTo(&layout.lines[7], 0));
    try std.testing.expectEqualStrings("... 1 more orders", std.mem.sliceTo(&layout.lines[10], 0));
}

test "details hide absent stats and resources, keep empty applicable bars and clamp fill" {
    var unit: data.Unit = .{ .tag = 1, .type_id = 45, .owner = 1, .position = .{}, .radius = 1, .visible = true, .flying = false, .order_start = 0, .order_count = 0 };
    const scene: data.Scene = .{};
    const absent = build(&scene, &unit, 64);
    try std.testing.expectEqual(@as(usize, 3), absent.count);
    try std.testing.expectEqual(absent.count, absent.heightCells());
    unit.health_max = 100;
    unit.health = -1;
    unit.energy_max = 200;
    unit.energy = 250;
    unit.shield_max = std.math.nan(f32);
    const clamped = build(&scene, &unit, 64);
    try std.testing.expectEqual(@as(usize, 5), clamped.count);
    try std.testing.expectEqual(@as(f32, 0), clamped.bars[2].?.fraction);
    try std.testing.expectEqual(@as(f32, 1), clamped.bars[3].?.fraction);
    unit.energy = 0;
    const empty_energy = build(&scene, &unit, 12);
    try std.testing.expectEqual(@as(f32, 0), empty_energy.bars[3].?.fraction);
    for (empty_energy.lines[0..empty_energy.count]) |row| try std.testing.expect(std.mem.sliceTo(&row, 0).len <= 12);
    unit.health = std.math.inf(f32);
    unit.energy_max = 0;
    try std.testing.expectEqual(@as(usize, 3), build(&scene, &unit, 64).count);
}

test "order text bounds queue size, missing targets, long text and no orders" {
    var orders: [20]data.Order = @splat(.{ .ability_id = 16, .progress = 0, .target = .{ .unit = 999 } });
    var units = [_]data.Unit{.{ .tag = 1, .type_id = 45, .owner = 1, .position = .{}, .radius = 0.375, .visible = true, .flying = false, .order_start = 0, .order_count = orders.len }};
    const scene: data.Scene = .{ .units = &units, .orders = &orders };
    const layout = build(&scene, &units[0], 20);
    try std.testing.expectEqual(@as(usize, 5), layout.count);
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
