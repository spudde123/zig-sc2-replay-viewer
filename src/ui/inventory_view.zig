//! Frame-aligned ready counts plus the production view's existing in-progress counts.
const std = @import("std");
const data = @import("../replay/replay_data.zig");
const production = @import("production_view.zig");
pub const Tab = enum { production, units, structures, losses };
pub const Group = struct {
    owner: i32,
    product: data.Product,
    ready: usize = 0,
    building: usize = 0,
};
pub const Summary = struct {
    groups: [production.max_groups]Group = undefined,
    count: usize = 0,
    omitted: usize = 0,

    fn add(self: *Summary, owner: i32, product: data.Product, ready: usize, building: usize) void {
        for (self.groups[0..self.count]) |*group| {
            if (group.owner == owner and group.product.key == product.key) {
                group.ready += ready;
                group.building += building;
                return;
            }
        }
        if (self.count == self.groups.len) {
            self.omitted += ready + building;
            return;
        }
        self.groups[self.count] = .{ .owner = owner, .product = product, .ready = ready, .building = building };
        self.count += 1;
    }
};
fn validOwner(owner: i32) bool {
    return owner > 0 and owner < 16;
}

pub fn summarize(scene: *const data.Scene, structures: bool) Summary {
    var summary: Summary = .{};
    for (scene.units) |unit| {
        if (!unit.visible or !validOwner(unit.owner) or unit.is_structure != structures or
            !std.math.isFinite(unit.build_progress) or unit.build_progress < 1) continue;
        summary.add(unit.owner, .{ .key = unit.type_id, .kind = .unit, .name = unit.name, .is_structure = unit.is_structure }, 1, 0);
    }
    if (!structures) {
        // Passenger records are sorted by tag during capture. Do not count a
        // passenger twice if SC2 also includes it in the top-level raw units.
        var previous: ?u64 = null;
        for (scene.passengers) |passenger| {
            if (previous == passenger.tag) continue;
            previous = passenger.tag;
            if (!passenger.visible or !validOwner(passenger.owner) or passenger.tag == 0) continue;
            if (scene.find(passenger.tag)) |unit| {
                if (unit.visible and !unit.is_structure and std.math.isFinite(unit.build_progress) and unit.build_progress >= 1) continue;
            }
            summary.add(passenger.owner, .{ .key = passenger.type_id, .kind = .unit, .name = passenger.name }, 1, 0);
        }
    }
    const pending = production.summarize(scene);
    for (pending.groups[0..pending.count]) |group| {
        if (group.product.kind != .unit or group.product.is_structure != structures) continue;
        summary.add(group.owner, group.product, 0, group.count);
    }
    // The source summary does not identify which tab lost an overflow entry.
    summary.omitted += pending.omitted_items;
    std.mem.sort(Group, summary.groups[0..summary.count], {}, struct {
        fn less(_: void, a: Group, b: Group) bool {
            if (a.owner != b.owner) return a.owner < b.owner;
            const names = std.mem.order(u8, std.mem.sliceTo(&a.product.name, 0), std.mem.sliceTo(&b.product.name, 0));
            if (names != .eq) return names == .lt;
            return a.product.key < b.product.key;
        }
    }.less);
    return summary;
}

fn add(layout: *production.Layout, kind: @FieldType(production.Row, "kind"), value: []const u8, columns: usize) void {
    var row: production.Row = .{ .kind = kind };
    const n = @min(value.len, std.math.clamp(columns, 1, row.text.len));
    @memcpy(row.text[0..n], value[0..n]);
    for (row.text[0..n]) |*c| if (c.* < 32 or c.* > 126) {
        c.* = '?';
    };
    layout.rows[layout.count] = row;
    layout.count += 1;
}
fn overflow(layout: *production.Layout, count: usize, columns: usize) void {
    var buffer: [80]u8 = undefined;
    add(layout, .overflow, std.fmt.bufPrint(&buffer, "{d} items not shown", .{count}) catch unreachable, columns);
}

pub fn build(summary: *const Summary, players: *const data.Players, rows: usize, columns: usize) production.Layout {
    var layout: production.Layout = .{};
    const limit = @min(rows, production.max_rows);
    if (limit == 0) return layout;
    var owner_players = players.*;
    for (summary.groups[0..summary.count]) |group| {
        const id: u32 = @intCast(group.owner);
        if (owner_players.slotForId(id) == null) owner_players.add(id, "");
    }
    std.mem.sort(data.Players.Player, owner_players.items[0..owner_players.count], {}, struct {
        fn less(_: void, a: data.Players.Player, b: data.Players.Player) bool {
            return a.id < b.id;
        }
    }.less);
    var owners = owner_players.count;
    if (owners == 0) {
        add(&layout, .empty, "No units reported", columns);
        return layout;
    }
    const reserve: usize = if (summary.omitted > 0) 1 else 0;
    const available = limit - reserve;
    if (available < owners * 2) {
        var omitted = summary.omitted;
        for (summary.groups[0..summary.count]) |group| omitted += group.ready + group.building;
        overflow(&layout, omitted, columns);
        return layout;
    }
    for (owner_players.items[0..owner_players.count]) |player| {
        const owner: i32 = @intCast(player.id);
        var begin: usize = 0;
        while (begin < summary.count and summary.groups[begin].owner < owner) begin += 1;
        var end = begin;
        while (end < summary.count and summary.groups[end].owner == owner) end += 1;
        const quota = (available - layout.count) / owners;
        const groups = end - begin;
        const shown = if (groups + 1 <= quota) groups else quota - 2;
        var buffer: [128]u8 = undefined;
        const name = players.name(@intCast(owner)) orelse std.fmt.bufPrint(&buffer, "Player {d}", .{owner}) catch unreachable;
        add(&layout, .heading, name, columns);
        if (groups == 0) add(&layout, .empty, "None reported", columns);
        var omitted: usize = 0;
        for (summary.groups[begin..end], 0..) |group, i| {
            if (i >= shown) {
                omitted += group.ready + group.building;
                continue;
            }
            var suffix: [64]u8 = undefined;
            const counts = std.fmt.bufPrint(&suffix, ": R:{d} B:{d}", .{ group.ready, group.building }) catch unreachable;
            const space = std.math.clamp(columns, 1, @as(usize, 64));
            const name_limit = space -| counts.len;
            const source = std.mem.sliceTo(&group.product.name, 0);
            const n = @min(name_limit, source.len);
            @memcpy(buffer[0..n], source[0..n]);
            if (source.len > n and n >= 3) @memcpy(buffer[n - 3 .. n], "...");
            @memcpy(buffer[n..][0..counts.len], counts);
            add(&layout, .product, buffer[0 .. n + counts.len], columns);
            const length = @min(n + counts.len, space);
            layout.rows[layout.count - 1].counts = .{
                .ready_begin = @min(n + 2, length),
                .building_begin = @min(n + (std.mem.indexOf(u8, counts, " B:").? + 1), length),
                .ready = group.ready,
                .building = group.building,
            };
        }
        if (omitted > 0) overflow(&layout, omitted, columns);
        owners -= 1;
    }
    if (reserve > 0) overflow(&layout, summary.omitted, columns);
    return layout;
}

fn testUnit(tag: u64, owner: i32, type_id: u32, structure: bool, progress: f32, name: []const u8) data.Unit {
    var u: data.Unit = .{ .tag = tag, .owner = owner, .type_id = type_id, .is_structure = structure, .build_progress = progress, .position = .{}, .radius = 1, .visible = true, .flying = false, .order_start = 0, .order_count = 0 };
    @memcpy(u.name[0..name.len], name);
    return u;
}
test "inventory merges ready units, deduplicated passengers and existing production counts by owner and type" {
    var units = [_]data.Unit{ testUnit(1, 3, 21, true, 1, "Barracks"), testUnit(2, 3, 48, false, 1, "Marine"), testUnit(3, 7, 45, false, 1, "SCV"), testUnit(4, 3, 21, true, 0.5, "Barracks"), testUnit(6, 3, 18, true, 1, "CommandCenter") };
    var product: data.Product = .{ .key = 48, .kind = .unit };
    @memcpy(product.name[0..6], "Marine");
    var orbital: data.Product = .{ .key = 132, .kind = .unit, .is_structure = true, .replaces_construction = true };
    @memcpy(orbital.name[0..14], "OrbitalCommand");
    var orders = [_]data.Order{
        .{ .ability_id = 560, .product = product, .progress = 0.5, .target = .none },
        .{ .ability_id = 1516, .product = orbital, .progress = 0, .target = .none },
    };
    units[0].order_count = 1;
    units[4].order_start = 1;
    units[4].order_count = 1;
    var passengers = [_]data.Passenger{
        .{ .tag = 2, .type_id = 48, .owner = 3, .visible = true },
        .{ .tag = 5, .type_id = 48, .owner = 3, .visible = true },
        .{ .tag = 5, .type_id = 48, .owner = 3, .visible = true },
    };
    for (&passengers) |*p| @memcpy(p.name[0..6], "Marine");
    const scene: data.Scene = .{ .units = &units, .orders = &orders, .passengers = &passengers };
    const summary = summarize(&scene, false);
    try std.testing.expectEqual(@as(usize, 2), summary.count);
    try std.testing.expectEqual(@as(usize, 2), summary.groups[0].ready);
    try std.testing.expectEqual(@as(usize, 1), summary.groups[0].building);
    const structures = summarize(&scene, true);
    try std.testing.expectEqual(@as(usize, 3), structures.count);
    try std.testing.expectEqual(@as(usize, 1), structures.groups[0].ready);
    try std.testing.expectEqual(@as(usize, 1), structures.groups[0].building);
    try std.testing.expectEqualStrings("CommandCenter", std.mem.sliceTo(&structures.groups[1].product.name, 0));
    try std.testing.expectEqual(@as(usize, 1), structures.groups[1].ready);
    try std.testing.expectEqualStrings("OrbitalCommand", std.mem.sliceTo(&structures.groups[2].product.name, 0));
    try std.testing.expectEqual(@as(usize, 0), structures.groups[2].ready);
    try std.testing.expectEqual(@as(usize, 1), structures.groups[2].building);
    const players: data.Players = .{};
    const layout = build(&summary, &players, 6, 40);
    try std.testing.expectEqualStrings("Marine: R:2 B:1", std.mem.sliceTo(&layout.rows[1].text, 0));
    const counts = layout.rows[1].counts.?;
    try std.testing.expectEqualStrings("Marine: ", layout.rows[1].text[0..counts.ready_begin]);
    try std.testing.expectEqualStrings("R:2 ", layout.rows[1].text[counts.ready_begin..counts.building_begin]);
    try std.testing.expectEqualStrings("B:1", std.mem.sliceTo(&layout.rows[1].text, 0)[counts.building_begin..]);
    try std.testing.expectEqual(@as(usize, 2), counts.ready);
    try std.testing.expectEqual(@as(usize, 1), counts.building);
    try std.testing.expectEqualStrings("SCV: R:1 B:0", std.mem.sliceTo(&layout.rows[3].text, 0));
    try std.testing.expectEqual(@as(usize, 0), build(&summary, &players, 0, 40).count);
}
test "inventory shares limited rows, preserves count suffixes and shows empty player sections" {
    var summary: Summary = .{};
    for ([_]i32{ 1, 2 }) |owner| {
        for (0..4) |i| {
            var p: data.Product = .{ .key = i, .kind = .unit };
            @memcpy(p.name[0..25], "VeryLongUnitTypeNameHere!");
            summary.add(owner, p, 3, 1);
        }
    }
    var players: data.Players = .{};
    players.add(1, "Alice");
    players.add(2, "Bob");
    const layout = build(&summary, &players, 6, 24);
    try std.testing.expectEqual(@as(usize, 6), layout.count);
    try std.testing.expect(std.mem.endsWith(u8, std.mem.sliceTo(&layout.rows[1].text, 0), ": R:3 B:1"));
    try std.testing.expectEqualStrings("Bob", std.mem.sliceTo(&layout.rows[3].text, 0));
    try std.testing.expect(layout.rows[2].kind == .overflow and layout.rows[5].kind == .overflow);
    const empty = build(&.{}, &players, 4, 40);
    try std.testing.expectEqual(@as(usize, 4), empty.count);
    try std.testing.expectEqualStrings("None reported", std.mem.sliceTo(&empty.rows[1].text, 0));
}
