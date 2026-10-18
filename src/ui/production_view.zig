//! Allocation-free grouping/layout of frame-aligned construction, training and research.
const std = @import("std");
const data = @import("../replay/replay_data.zig");
pub const max_groups = 128;
// Enough rows for every bounded group plus player headings and overflow.
pub const max_rows = max_groups + data.max_players + 1;
pub const max_bars = 3;
pub const Group = struct {
    owner: i32,
    product: data.Product,
    count: usize = 0,
    unknown_progress: usize = 0,
    bars: [max_bars]f32 = @splat(0),
};
pub const Summary = struct {
    groups: [max_groups]Group = undefined,
    count: usize = 0,
    omitted_items: usize = 0,

    fn add(self: *Summary, owner: i32, product: data.Product, progress: ?f32) void {
        var index: usize = 0;
        while (index < self.count) : (index += 1) {
            const group = &self.groups[index];
            if (group.owner == owner and group.product.key == product.key and group.product.kind == product.kind) break;
        }
        if (index == self.count) {
            if (self.count == max_groups) {
                self.omitted_items += 1;
                return;
            }
            self.groups[index] = .{ .owner = owner, .product = product };
            self.count += 1;
        }
        const group = &self.groups[index];
        // Keep known progress first, furthest along first; unknowns use separate bars.
        if (progress) |value| {
            var carry = value;
            for (&group.bars) |*bar| {
                if (carry > bar.*) {
                    const old = bar.*;
                    bar.* = carry;
                    carry = old;
                }
            }
        } else group.unknown_progress += 1;
        group.count += 1;
    }
};
fn active(progress: f32) bool {
    return std.math.isFinite(progress) and progress > 0 and progress < 1;
}

pub fn summarize(scene: *const data.Scene) Summary {
    var summary: Summary = .{};
    for (scene.units) |unit| {
        if (!unit.visible or unit.owner <= 0 or unit.owner >= 16) continue;
        const incomplete = active(unit.build_progress);
        const name = std.mem.sliceTo(&unit.name, 0);
        const shell = std.mem.indexOf(u8, name, "Egg") != null or std.mem.indexOf(u8, name, "Cocoon") != null;
        var replaced = false;
        for (scene.ordersFor(&unit), 0..) |order, index| {
            const product = order.product orelse continue;
            const ongoing = active(order.progress);
            const same_type = product.key == unit.type_id;
            if (incomplete and product.kind == .unit and (shell or same_type or product.replaces_construction) and
                (ongoing or shell or same_type))
            {
                // Egg/cocoon orders sometimes report zero while the shell's
                // build_progress advances. Show its result, not a second Egg row.
                if (!replaced) summary.add(unit.owner, product, if (ongoing) order.progress else unit.build_progress);
                replaced = true;
            } else if (ongoing) {
                summary.add(unit.owner, product, order.progress);
            } else if (index == 0 and unit.is_structure and
                std.math.isFinite(unit.build_progress) and unit.build_progress >= 1 and
                product.kind == .unit and product.is_structure and product.replaces_construction and order.progress == 0)
            {
                // Building upgrades can execute with no order progress in SC2.
                // Only the first order on a completed source is considered active.
                summary.add(unit.owner, product, null);
            }
        }
        if (incomplete and !replaced) {
            summary.add(unit.owner, .{ .key = unit.type_id, .kind = .unit, .name = unit.name, .is_structure = unit.is_structure }, unit.build_progress);
        }
    }
    std.mem.sort(Group, summary.groups[0..summary.count], {}, struct {
        fn less(_: void, a: Group, b: Group) bool {
            if (a.owner != b.owner) return a.owner < b.owner;
            if (a.product.kind != b.product.kind) return a.product.kind == .unit;
            const names = std.mem.order(u8, std.mem.sliceTo(&a.product.name, 0), std.mem.sliceTo(&b.product.name, 0));
            if (names != .eq) return names == .lt;
            return a.product.key < b.product.key;
        }
    }.less);
    return summary;
}

fn testUnit(tag: u64, owner: i32, type_id: u32, progress: f32, name: []const u8) data.Unit {
    var unit: data.Unit = .{ .tag = tag, .owner = owner, .type_id = type_id, .position = .{}, .radius = 1, .visible = true, .flying = false, .order_start = 0, .order_count = 0, .build_progress = progress };
    @memcpy(unit.name[0..name.len], name);
    return unit;
}
fn testProduct(key: u64, kind: data.Product.Kind, name: []const u8) data.Product {
    var product: data.Product = .{ .key = key, .kind = kind };
    @memcpy(product.name[0..name.len], name);
    return product;
}

test "production groups owners and types, keeps top three bars and counts overflow" {
    var units: [9]data.Unit = undefined;
    for (0..7) |i| units[i] = testUnit(i + 1, 1, 19, @as(f32, @floatFromInt(i + 1)) / 10, "SupplyDepot");
    units[7] = testUnit(8, 2, 19, 0.4, "SupplyDepot");
    units[8] = testUnit(9, 16, 19, 0.5, "SupplyDepot");
    const summary = summarize(&.{ .units = &units });
    try std.testing.expectEqual(@as(usize, 2), summary.count);
    try std.testing.expectEqual(@as(usize, 7), summary.groups[0].count);
    try std.testing.expectApproxEqAbs(@as(f32, 0.7), summary.groups[0].bars[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), summary.groups[0].bars[2], 0.001);
    var players: data.Players = .{};
    players.add(1, "Alice");
    players.add(2, "Bob");
    const layout = build(&summary, &players, 10, 40, 20);
    try std.testing.expectEqual(@as(usize, 4), layout.count);
    try std.testing.expectEqualStrings("Alice", std.mem.sliceTo(&layout.rows[0].text, 0));
    try std.testing.expectEqual(@as(usize, 3), layout.rows[1].bar_count);
    try std.testing.expectEqual(@as(usize, 4), layout.rows[1].more);
    try std.testing.expectEqualStrings("Bob", std.mem.sliceTo(&layout.rows[2].text, 0));
    const clipped = build(&summary, &players, 1, 40, 20);
    try std.testing.expect(clipped.rows[0].kind == .overflow);
    try std.testing.expectEqualStrings("8 active items not shown", std.mem.sliceTo(&clipped.rows[0].text, 0));
}

test "training and research include parallel active orders, not zero queues, moves or completed jobs" {
    var units = [_]data.Unit{testUnit(1, 1, 21, 1, "Barracks")};
    const marine = testProduct(48, .unit, "Marine");
    const upgrade = testProduct(7, .research, "InfantryWeapons1");
    var orders = [_]data.Order{
        .{ .ability_id = 560, .progress = 0.3, .target = .none, .product = marine },
        .{ .ability_id = 560, .progress = 0.6, .target = .none, .product = marine },
        .{ .ability_id = 560, .progress = 0, .target = .none, .product = marine },
        .{ .ability_id = 652, .progress = 0.4, .target = .none, .product = upgrade },
        .{ .ability_id = 16, .progress = 0.5, .target = .none },
        .{ .ability_id = 560, .progress = 1, .target = .none, .product = marine },
    };
    units[0].order_count = orders.len;
    const summary = summarize(&.{ .units = &units, .orders = &orders });
    try std.testing.expectEqual(@as(usize, 2), summary.count);
    try std.testing.expectEqual(@as(usize, 2), summary.groups[0].count);
    try std.testing.expect(summary.groups[1].product.kind == .research);
    for (&orders) |*order| order.progress = 1;
    try std.testing.expectEqual(@as(usize, 0), summarize(&.{ .units = &units, .orders = &orders }).count);
    units[0].visible = false;
    orders[0].progress = 0.5;
    try std.testing.expectEqual(@as(usize, 0), summarize(&.{ .units = &units, .orders = &orders }).count);
    try std.testing.expectEqual(@as(usize, 0), summarize(&.{}).count);
}

test "eggs and morphs replace construction, while ordinary construction merges with training results" {
    var units = [_]data.Unit{
        testUnit(1, 1, 103, 0.4, "Egg"),
        testUnit(2, 1, 48, 0.3, "Marine"),
        testUnit(3, 1, 21, 1, "Barracks"),
        testUnit(4, 1, 86, 0.5, "Hatchery"),
    };
    var lair = testProduct(100, .unit, "Lair");
    lair.replaces_construction = true;
    var orders = [_]data.Order{
        .{ .ability_id = 1342, .progress = 0, .target = .none, .product = testProduct(104, .unit, "Drone") },
        .{ .ability_id = 560, .progress = 0.6, .target = .none, .product = testProduct(48, .unit, "Marine") },
        .{ .ability_id = 1216, .progress = 0.5, .target = .none, .product = lair },
    };
    units[0].order_count = 1;
    units[2].order_start = 1;
    units[2].order_count = 1;
    units[3].order_start = 2;
    units[3].order_count = 1;
    const summary = summarize(&.{ .units = &units, .orders = &orders });
    try std.testing.expectEqual(@as(usize, 3), summary.count);
    try std.testing.expectEqualStrings("Drone", std.mem.sliceTo(&summary.groups[0].product.name, 0));
    try std.testing.expectEqualStrings("Lair", std.mem.sliceTo(&summary.groups[1].product.name, 0));
    try std.testing.expectEqual(@as(usize, 2), summary.groups[2].count);
    // A queued morph on an unfinished source must not replace its construction.
    orders[2].progress = 0;
    const queued = summarize(&.{ .units = &units, .orders = &orders });
    try std.testing.expectEqualStrings("Hatchery", std.mem.sliceTo(&queued.groups[1].product.name, 0));
}

test "zero-progress building upgrades are shown only as the first order on completed structures" {
    var source = testUnit(1, 1, 18, 1, "CommandCenter");
    source.is_structure = true;
    source.order_count = 1;
    var orbital = testProduct(132, .unit, "OrbitalCommand");
    orbital.is_structure = true;
    orbital.replaces_construction = true;
    var orders = [_]data.Order{
        .{ .ability_id = 1516, .progress = 0, .target = .none, .product = orbital },
        .{ .ability_id = 524, .progress = 0.5, .target = .none, .product = testProduct(45, .unit, "SCV") },
    };
    var units = [_]data.Unit{source};
    const scene: data.Scene = .{ .units = &units, .orders = &orders };
    const active_upgrade = summarize(&scene);
    try std.testing.expectEqual(@as(usize, 1), active_upgrade.count);
    try std.testing.expectEqual(@as(usize, 1), active_upgrade.groups[0].unknown_progress);
    const layout = build(&active_upgrade, &.{}, 8, 48, 28);
    try std.testing.expectEqualStrings("OrbitalCommand", std.mem.sliceTo(&layout.rows[1].text, 0));
    try std.testing.expectEqual(@as(usize, 1), layout.rows[1].unknown_bars);
    try std.testing.expectEqual(@as(usize, 1), layout.rows[1].bar_count);
    // A queued upgrade behind training must still be excluded.
    std.mem.swap(data.Order, &orders[0], &orders[1]);
    units[0].order_count = 2;
    const queued = summarize(&scene);
    try std.testing.expectEqual(@as(usize, 1), queued.count);
    try std.testing.expectEqual(@as(u64, 45), queued.groups[0].product.key);
    try std.testing.expectEqual(@as(usize, 0), queued.groups[0].unknown_progress);
    // Nor should an upgrade queued on an unfinished building replace construction.
    units[0].order_start = 1;
    units[0].order_count = 1;
    units[0].build_progress = 0.5;
    const unfinished = summarize(&scene);
    try std.testing.expectEqual(@as(u64, 18), unfinished.groups[0].product.key);
    try std.testing.expectEqual(@as(usize, 0), unfinished.groups[0].unknown_progress);
    units[0].build_progress = 1;
    orders[1].progress = 1;
    try std.testing.expectEqual(@as(usize, 0), summarize(&scene).count);
    units[0].order_count = 0; // Cancellation/removal also removes the entry.
    try std.testing.expectEqual(@as(usize, 0), summarize(&scene).count);
}

test "bounded grouping handles invalid progress and retains upgrade suffixes in clipped labels" {
    var units: [max_groups + 2]data.Unit = undefined;
    for (&units, 0..) |*unit, i| unit.* = testUnit(i + 1, 1, @intCast(i), 0.5, "Type");
    const summary = summarize(&.{ .units = &units });
    try std.testing.expectEqual(max_groups, summary.count);
    try std.testing.expectEqual(@as(usize, 2), summary.omitted_items);
    const players: data.Players = .{};
    try std.testing.expectEqual(@as(usize, 0), build(&summary, &players, 0, 40, 20).count);
    var row: Row = .{ .kind = .product };
    label(&row, "R: TerranInfantryWeaponsLevel1", 20);
    try std.testing.expect(std.mem.endsWith(u8, std.mem.sliceTo(&row.text, 0), "nsLevel1"));
    units[0].build_progress = std.math.nan(f32);
    units[1].build_progress = std.math.inf(f32);
    units[2].build_progress = 0;
    units[3].build_progress = 1;
    const invalid = summarize(&.{ .units = units[0..4] });
    try std.testing.expectEqual(@as(usize, 0), invalid.count);
    const empty = build(&invalid, &players, 5, 40, 20);
    try std.testing.expect(empty.rows[0].kind == .empty);
}

pub const Row = struct {
    kind: enum { heading, product, empty, overflow },
    text: [64:0]u8 = @splat(0),
    bars: [max_bars]f32 = @splat(0),
    bar_count: usize = 0,
    unknown_bars: usize = 0,
    more: usize = 0,
    research: bool = false,
    resource_values: bool = false,
    counts: ?struct { ready_begin: usize, building_begin: usize, ready: usize, building: usize } = null,
};
pub const Layout = struct {
    rows: [max_rows]Row = undefined,
    count: usize = 0,
    fn add(self: *Layout, row: Row) void {
        self.rows[self.count] = row;
        self.count += 1;
    }
};
fn label(row: *Row, value: []const u8, columns: usize) void {
    const limit = std.math.clamp(columns, 1, row.text.len);
    const n = @min(limit, value.len);
    @memcpy(row.text[0..n], value[0..n]);
    if (value.len > n and n >= 12) {
        // Retain upgrade level suffixes when a long label needs clipping.
        @memcpy(row.text[n - 11 .. n - 8], "...");
        @memcpy(row.text[n - 8 .. n], value[value.len - 8 ..]);
    }
    for (row.text[0..n]) |*byte| if (byte.* < 32 or byte.* > 126) {
        byte.* = '?';
    };
}

fn addOverflow(layout: *Layout, omitted: usize, columns: usize) void {
    var buffer: [80]u8 = undefined;
    var row: Row = .{ .kind = .overflow };
    label(&row, std.fmt.bufPrint(&buffer, "{d} active items not shown", .{omitted}) catch unreachable, columns);
    layout.add(row);
}

test "crowded panels share rows between players and prioritize their research" {
    var summary: Summary = .{};
    for ([_]i32{ 1, 2 }) |owner| {
        summary.add(owner, testProduct(48, .unit, "Marine"), 0.5);
        summary.add(owner, testProduct(45, .unit, "SCV"), 0.5);
        summary.add(owner, testProduct(33, .unit, "SiegeTank"), 0.5);
        summary.add(owner, testProduct(15, .research, "Stimpack"), 0.5);
    }
    const players: data.Players = .{};
    const layout = build(&summary, &players, 8, 40, 20);
    try std.testing.expectEqual(@as(usize, 8), layout.count);
    try std.testing.expectEqualStrings("Player 1", std.mem.sliceTo(&layout.rows[0].text, 0));
    try std.testing.expect(layout.rows[1].research);
    try std.testing.expect(layout.rows[3].kind == .overflow);
    try std.testing.expectEqualStrings("Player 2", std.mem.sliceTo(&layout.rows[4].text, 0));
    try std.testing.expect(layout.rows[5].research);
    try std.testing.expect(layout.rows[7].kind == .overflow);
}

pub fn build(summary: *const Summary, players: *const data.Players, rows: usize, columns: usize, label_columns: usize) Layout {
    var layout: Layout = .{};
    const limit = @min(rows, max_rows);
    if (limit == 0) return layout;
    if (summary.count == 0 and summary.omitted_items == 0) {
        var row: Row = .{ .kind = .empty };
        label(&row, "No active production reported", columns);
        layout.add(row);
        return layout;
    }
    var owners: usize = 0;
    var previous: i32 = -1;
    for (summary.groups[0..summary.count]) |group| {
        if (group.owner != previous) owners += 1;
        previous = group.owner;
    }
    const reserve: usize = if (summary.omitted_items > 0) 1 else 0;
    const available = limit - reserve;
    if (available < owners * 2) {
        var omitted = summary.omitted_items;
        for (summary.groups[0..summary.count]) |group| omitted += group.count;
        addOverflow(&layout, omitted, columns);
        return layout;
    }
    var index: usize = 0;
    while (index < summary.count) {
        const owner = summary.groups[index].owner;
        var end = index + 1;
        while (end < summary.count and summary.groups[end].owner == owner) end += 1;
        // Share limited space between players instead of hiding the second
        // player's section. Research comes first so it survives crowded panels.
        const quota = (available - layout.count) / owners;
        const group_count = end - index;
        const shown = if (group_count + 1 <= quota) group_count else quota - 2;
        var buffer: [128]u8 = undefined;
        var heading: Row = .{ .kind = .heading };
        const name = players.name(@intCast(owner)) orelse std.fmt.bufPrint(&buffer, "Player {d}", .{owner}) catch unreachable;
        label(&heading, name, columns);
        layout.add(heading);
        var displayed: usize = 0;
        var omitted: usize = 0;
        for ([_]data.Product.Kind{ .research, .unit }) |kind| {
            for (summary.groups[index..end]) |group| {
                if (group.product.kind != kind) continue;
                if (displayed == shown) {
                    omitted += group.count;
                    continue;
                }
                var row: Row = .{ .kind = .product, .bars = group.bars, .bar_count = @min(group.count, max_bars), .more = group.count - @min(group.count, max_bars), .research = kind == .research };
                row.unknown_bars = @min(group.unknown_progress, max_bars - @min(group.count - group.unknown_progress, max_bars));
                const value = std.fmt.bufPrint(&buffer, "{s}{s}", .{ if (row.research) "R: " else "", std.mem.sliceTo(&group.product.name, 0) }) catch unreachable;
                label(&row, value, label_columns);
                layout.add(row);
                displayed += 1;
            }
        }
        if (omitted > 0) addOverflow(&layout, omitted, columns);
        owners -= 1;
        index = end;
    }
    if (summary.omitted_items > 0) addOverflow(&layout, summary.omitted_items, columns);
    return layout;
}
