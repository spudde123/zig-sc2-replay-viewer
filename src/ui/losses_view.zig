//! Recorded cumulative resource losses plus exact, frame-aligned recent deaths.
const std = @import("std");
const losses = @import("../replay/losses.zig");
const data = @import("../replay/replay_data.zig");
const production = @import("production_view.zig");

fn add(layout: *production.Layout, kind: @FieldType(production.Row, "kind"), value: []const u8, columns: usize) void {
    var row: production.Row = .{ .kind = kind };
    const n = @min(value.len, @min(columns, row.text.len));
    @memcpy(row.text[0..n], value[0..n]);
    for (row.text[0..n]) |*ch| if (ch.* < 32 or ch.* > 126) {
        ch.* = '?';
    };
    layout.rows[layout.count] = row;
    layout.count += 1;
}

fn resourceRow(layout: *production.Layout, label: []const u8, value: ?data.ResourceLoss, status: []const u8, columns: usize) void {
    var buffer: [128]u8 = undefined;
    const text = if (value) |v|
        std.fmt.bufPrint(&buffer, "{s}: M:{d} V:{d}", .{ label, v.minerals, v.vespene }) catch unreachable
    else
        std.fmt.bufPrint(&buffer, "{s}: {s}", .{ label, status }) catch unreachable;
    add(layout, .product, text, columns);
    layout.rows[layout.count - 1].resource_values = value != null;
}

pub fn build(snapshot: *const losses.Snapshot, stats: *const data.PlayerStats, players: *const data.Players, rows: usize, columns: usize) production.Layout {
    var layout: production.Layout = .{};
    const limit = @min(rows, production.max_rows);
    if (limit == 0) return layout;
    if (!snapshot.available and !stats.available) {
        add(&layout, .empty, "Replay losses unavailable", columns);
        return layout;
    }
    // Heading, three resource categories, recent heading and at least one list row.
    if (players.count == 0 or limit < players.count * 6) {
        add(&layout, .empty, "Losses: more panel space needed", columns);
        return layout;
    }
    for (players.items[0..players.count], 0..) |player, slot| {
        const quota = (limit - layout.count) / (players.count - slot);
        var types: usize = 0;
        for (snapshot.groups) |group| {
            if (group.owner == player.id and group.recent > 0) types += 1;
        }
        var buffer: [128]u8 = undefined;
        const name = players.name(player.id) orelse std.fmt.bufPrint(&buffer, "Player {d}", .{player.id}) catch unreachable;
        add(&layout, .heading, name, columns);
        const sample = stats.forPlayer(player.id);
        const resources = if (sample) |s| s.resource_losses else null;
        const status: []const u8 = if (!stats.available or sample != null) "unavailable" else "pending";
        resourceRow(&layout, "Army", if (resources) |r| r.army else null, status, columns);
        resourceRow(&layout, "Econ", if (resources) |r| r.economy else null, status, columns);
        resourceRow(&layout, "Tech", if (resources) |r| r.technology else null, status, columns);
        add(&layout, .heading, "Deaths last 15s:", columns);
        if (!snapshot.available or types == 0) {
            add(&layout, .empty, if (snapshot.available) "No deaths in last 15s" else "Recent deaths unavailable", columns);
            continue;
        }
        const available = quota - 5;
        const shown = if (types <= available) types else available - 1;
        var displayed: usize = 0;
        var omitted: usize = 0;
        for (snapshot.groups) |group| {
            if (group.owner != player.id or group.recent == 0) continue;
            if (displayed >= shown) {
                omitted += group.recent;
                continue;
            }
            var suffix: [32]u8 = undefined;
            const count = std.fmt.bufPrint(&suffix, ": {d}", .{group.recent}) catch unreachable;
            const source = std.mem.sliceTo(&group.name, 0);
            const n = @min(source.len, columns -| count.len);
            @memcpy(buffer[0..n], source[0..n]);
            if (n < source.len and n >= 3) @memcpy(buffer[n - 3 .. n], "...");
            @memcpy(buffer[n..][0..count.len], count);
            add(&layout, .product, buffer[0 .. n + count.len], columns);
            displayed += 1;
        }
        if (omitted > 0) add(&layout, .overflow, std.fmt.bufPrint(&buffer, "{d} recent deaths not shown", .{omitted}) catch unreachable, columns);
    }
    return layout;
}

test "loss view shows recorded category values by player and only recent unit counts" {
    var players: data.Players = .{};
    players.add(7, "Alice");
    players.add(3, "Bob");
    var stats: data.PlayerStats = .{ .available = true, .player_ids = .{ 3, 7 } };
    stats.items[1] = .{
        .game_loop = 160,
        .minerals = 0,
        .vespene = 0,
        .food_used = 0,
        .food_cap = 0,
        .worker_supply = 0,
        .resource_losses = .{
            .army = .{ .minerals = 950, .vespene = 350 },
            .economy = .{ .minerals = 400, .vespene = 0 },
            .technology = .{ .minerals = 150, .vespene = 100 },
        },
    };
    var name: losses.Name = @splat(0);
    @memcpy(name[0..6], "Marine");
    var groups = [_]losses.Group{.{ .owner = 7, .name = name, .recent = 4 }};
    const result = build(&.{ .available = true, .groups = &groups }, &stats, &players, 12, 40);
    try std.testing.expectEqual(@as(usize, 12), result.count);
    try std.testing.expect(result.rows[1].resource_values and result.rows[2].resource_values and result.rows[3].resource_values);
    try std.testing.expect(!result.rows[0].resource_values and !result.rows[5].resource_values and !result.rows[7].resource_values);
    try std.testing.expectEqualStrings("Army: M:950 V:350", std.mem.sliceTo(&result.rows[1].text, 0));
    try std.testing.expectEqualStrings("Econ: M:400 V:0", std.mem.sliceTo(&result.rows[2].text, 0));
    try std.testing.expectEqualStrings("Tech: M:150 V:100", std.mem.sliceTo(&result.rows[3].text, 0));
    try std.testing.expectEqualStrings("Deaths last 15s:", std.mem.sliceTo(&result.rows[4].text, 0));
    try std.testing.expectEqualStrings("Marine: 4", std.mem.sliceTo(&result.rows[5].text, 0));
    try std.testing.expectEqualStrings("Bob", std.mem.sliceTo(&result.rows[6].text, 0));
    try std.testing.expectEqualStrings("Army: pending", std.mem.sliceTo(&result.rows[7].text, 0));
    try std.testing.expectEqualStrings("No deaths in last 15s", std.mem.sliceTo(&result.rows[11].text, 0));
}

test "loss view distinguishes unavailable and missing category data from zero" {
    var players: data.Players = .{};
    players.add(3, "Alice");
    const unavailable = build(&.{}, &.{}, &players, 6, 40);
    try std.testing.expectEqualStrings("Replay losses unavailable", std.mem.sliceTo(&unavailable.rows[0].text, 0));
    try std.testing.expectEqual(@as(usize, 0), build(&.{}, &.{}, &players, 0, 40).count);
    var stats: data.PlayerStats = .{ .available = true, .player_ids = .{ 3, 0 } };
    stats.items[0] = .{ .game_loop = 0, .minerals = 0, .vespene = 0, .food_used = 0, .food_cap = 0, .worker_supply = 0 };
    const missing = build(&.{ .available = true }, &stats, &players, 6, 40);
    try std.testing.expect(!missing.rows[1].resource_values);
    try std.testing.expectEqualStrings("Army: unavailable", std.mem.sliceTo(&missing.rows[1].text, 0));
    const zero: data.ResourceLoss = .{ .minerals = 0, .vespene = 0 };
    stats.items[0].?.resource_losses = .{ .army = zero, .economy = zero, .technology = zero };
    const empty = build(&.{ .available = true }, &stats, &players, 6, 40);
    try std.testing.expectEqualStrings("Army: M:0 V:0", std.mem.sliceTo(&empty.rows[1].text, 0));
    const small = build(&.{ .available = true }, &stats, &players, 5, 40);
    try std.testing.expectEqualStrings("Losses: more panel space needed", std.mem.sliceTo(&small.rows[0].text, 0));
}

test "recent list overflow shares rows between players and counts omitted deaths" {
    var players: data.Players = .{};
    players.add(3, "Alice");
    players.add(7, "Bob");
    var groups: [4]losses.Group = undefined;
    for (&groups, 0..) |*group, i| {
        group.* = .{ .owner = if (i < 2) 3 else 7, .name = @splat(0), .recent = i + 1 };
        const name: []const u8 = if (i % 2 == 0) "Marine" else "Marauder";
        @memcpy(group.name[0..name.len], name);
    }
    const result = build(&.{ .available = true, .groups = &groups }, &.{}, &players, 12, 40);
    try std.testing.expectEqual(@as(usize, 12), result.count);
    try std.testing.expectEqualStrings("3 recent deaths not shown", std.mem.sliceTo(&result.rows[5].text, 0));
    try std.testing.expectEqualStrings("7 recent deaths not shown", std.mem.sliceTo(&result.rows[11].text, 0));
}
