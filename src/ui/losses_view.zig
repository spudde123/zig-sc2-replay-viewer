//! Losses are already aligned to the displayed frame by the replay worker.
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

pub fn build(snapshot: *const losses.Snapshot, players: *const data.Players, rows: usize, columns: usize) production.Layout {
    var layout: production.Layout = .{};
    const limit = @min(rows, production.max_rows);
    if (limit == 0) return layout;
    if (!snapshot.available) {
        add(&layout, .empty, "Replay losses unavailable", columns);
        return layout;
    }
    if (players.count == 0 or limit < players.count * 4) {
        add(&layout, .empty, "Losses: more panel space needed", columns);
        return layout;
    }
    for (players.items[0..players.count], 0..) |player, slot| {
        const quota = (limit - layout.count) / (players.count - slot);
        var total: usize = 0;
        var workers: usize = 0;
        var recent: usize = 0;
        var types: usize = 0;
        for (snapshot.groups) |group| {
            if (group.owner != player.id) continue;
            total += group.total;
            if (losses.isWorker(std.mem.sliceTo(&group.name, 0))) workers += group.total;
            recent += group.recent;
            if (group.recent > 0) types += 1;
        }
        var buffer: [128]u8 = undefined;
        const name = players.name(player.id) orelse std.fmt.bufPrint(&buffer, "Player {d}", .{player.id}) catch unreachable;
        add(&layout, .heading, name, columns);
        add(&layout, .product, std.fmt.bufPrint(&buffer, "Deaths: game {d} | 15s {d}", .{ total, recent }) catch unreachable, columns);
        add(&layout, .product, std.fmt.bufPrint(&buffer, "Workers lost (game): {d}", .{workers}) catch unreachable, columns);
        if (types == 0) {
            add(&layout, .empty, "No deaths in last 15s", columns);
            continue;
        }
        const available = quota - 3;
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

test "game worker totals persist outside recent window and stay separate by owner" {
    var players: data.Players = .{};
    players.add(3, "Alice");
    players.add(7, "Bob");
    const names = [_][]const u8{ "SCV", "Probe", "Drone", "DroneBurrowed", "MULE", "Marine" };
    var deaths: [8]losses.Death = undefined;
    for (names, 0..) |name, i| {
        deaths[i] = .{ .game_loop = 1, .owner = 3, .name = @splat(0) };
        @memcpy(deaths[i].name[0..name.len], name);
    }
    deaths[6] = deaths[0];
    deaths[6].owner = 7;
    deaths[7] = deaths[0];
    deaths[7].game_loop = 1001; // Future deaths must not count yet.
    const snapshot = try losses.snapshot(std.testing.allocator, &deaths, 1000);
    defer snapshot.deinit(std.testing.allocator);
    const result = build(&snapshot, &players, 8, 40);
    try std.testing.expectEqualStrings("Deaths: game 6 | 15s 0", std.mem.sliceTo(&result.rows[1].text, 0));
    try std.testing.expectEqualStrings("Workers lost (game): 4", std.mem.sliceTo(&result.rows[2].text, 0));
    try std.testing.expectEqualStrings("Workers lost (game): 1", std.mem.sliceTo(&result.rows[6].text, 0));
    const small = build(&snapshot, &players, 7, 40);
    try std.testing.expectEqualStrings("Losses: more panel space needed", std.mem.sliceTo(&small.rows[0].text, 0));
}

test "loss view shares rows, shows totals and recent counts, distinguishes unavailable from zero" {
    var players: data.Players = .{};
    players.add(3, "Alice");
    players.add(7, "Bob");
    var name: losses.Name = @splat(0);
    @memcpy(name[0..6], "Marine");
    var groups = [_]losses.Group{.{ .owner = 3, .name = name, .total = 12, .recent = 4 }};
    const result = build(&.{ .available = true, .groups = &groups }, &players, 8, 40);
    try std.testing.expectEqual(@as(usize, 8), result.count);
    try std.testing.expectEqualStrings("Deaths: game 12 | 15s 4", std.mem.sliceTo(&result.rows[1].text, 0));
    try std.testing.expectEqualStrings("Workers lost (game): 0", std.mem.sliceTo(&result.rows[2].text, 0));
    try std.testing.expectEqualStrings("Marine: 4", std.mem.sliceTo(&result.rows[3].text, 0));
    try std.testing.expectEqualStrings("Bob", std.mem.sliceTo(&result.rows[4].text, 0));
    try std.testing.expectEqualStrings("No deaths in last 15s", std.mem.sliceTo(&result.rows[7].text, 0));
    const unavailable = build(&.{}, &players, 6, 40);
    try std.testing.expectEqualStrings("Replay losses unavailable", std.mem.sliceTo(&unavailable.rows[0].text, 0));
    try std.testing.expectEqual(@as(usize, 0), build(&.{}, &players, 0, 40).count);
    groups[0].recent = 0;
    const old = build(&.{ .available = true, .groups = &groups }, &players, 8, 40);
    try std.testing.expectEqualStrings("Deaths: game 12 | 15s 0", std.mem.sliceTo(&old.rows[1].text, 0));
}
