const std = @import("std");
const sc2 = @import("zig-sc2");
const Mapping = @import("minimap_mapping.zig").Mapping;

pub const Label = struct {
    id: u32 = 0,
    name: [48:0]u8 = @splat(0),
    // Normalized square minimap coordinates (including padding); y increases upwards.
    x: f32 = 0,
    y: f32 = 0,
};

pub const Labels = struct {
    items: [16]Label = @splat(.{}),
    count: usize = 0,
};

/// Capture once, so names remain anchored at the starting bases throughout playback.
/// No marker is invented for players whose starting units are unavailable.
pub fn capture(players: []const sc2.ReplaySession.Player, obs: sc2.sc2p.ResponseObservation, mapping: Mapping) Labels {
    var result: Labels = .{};
    if (mapping.width <= 0 or mapping.height <= 0) return result;
    const observation = obs.observation orelse return result;
    const raw = observation.raw orelse return result;
    for (players) |player| {
        if (result.count == result.items.len) break;
        var position: ?@FieldType(sc2.sc2p.Unit, "position") = null;
        for (raw.units) |unit| {
            if (unit.owner <= 0 or @as(u32, @intCast(unit.owner)) != player.id) continue;
            if (position == null) position = unit.position;
            if (unit.unit_type == .CommandCenter or unit.unit_type == .Nexus or unit.unit_type == .Hatchery or
                unit.unit_type == .OrbitalCommand or unit.unit_type == .PlanetaryFortress or
                unit.unit_type == .Lair or unit.unit_type == .Hive)
            {
                position = unit.position;
                break;
            }
        }
        const pos = position orelse continue;
        const point = mapping.toImage(.{ .x = pos.x, .y = pos.y });
        var label: Label = .{ .id = player.id, .x = point.x, .y = point.y };
        setName(&label, std.mem.sliceTo(&player.name, 0));
        result.items[result.count] = label;
        result.count += 1;
    }
    return result;
}

fn setName(label: *Label, original: []const u8) void {
    const name = std.mem.trim(u8, original, " \t\r\n");
    label.name = @splat(0);
    if (name.len == 0) {
        // Keep unnamed players distinguishable without prefixing actual names.
        _ = std.fmt.bufPrint(label.name[0..label.name.len], "Player {d}", .{label.id}) catch unreachable;
    } else {
        const len = @min(name.len, label.name.len);
        @memcpy(label.name[0..len], name[0..len]);
        // Sokol's bitmap font is ASCII. Prevent control characters from changing layout.
        for (label.name[0..len]) |*byte| if (byte.* < 32 or byte.* > 126) {
            byte.* = '?';
        };
    }
}

test "label names are bounded and unnamed players have distinct fallbacks" {
    var label: Label = .{ .id = 2 };
    setName(&label, "Clem");
    try std.testing.expectEqualStrings("Clem", std.mem.sliceTo(&label.name, 0));
    const long_name: [80]u8 = @splat('a');
    setName(&label, &long_name);
    try std.testing.expectEqual(@as(usize, 48), std.mem.sliceTo(&label.name, 0).len);
    try std.testing.expectEqual(@as(u8, 0), label.name[48]);
    setName(&label, "");
    try std.testing.expectEqualStrings("Player 2", std.mem.sliceTo(&label.name, 0));
    label.id = 1;
    setName(&label, " \t\r\n");
    try std.testing.expectEqualStrings("Player 1", std.mem.sliceTo(&label.name, 0));
}

test "labels use ownership, prefer bases, omit unseen players and own names" {
    var players = [_]sc2.ReplaySession.Player{ .{ .id = 1 }, .{ .id = 2 }, .{ .id = 3 } };
    @memcpy(players[0].name[0..4], "Maru");
    @memcpy(players[1].name[0..4], "Clem");
    var units = [_]sc2.sc2p.Unit{
        .{ .owner = 16, .position = .{ .x = 50, .y = 50 } },
        .{ .owner = 1, .position = .{ .x = 30, .y = 30 } },
        .{ .owner = 1, .unit_type = .CommandCenter, .position = .{ .x = 20, .y = 40 } },
        .{ .owner = 2, .unit_type = .CommandCenter, .position = .{ .x = 80, .y = 160 } },
    };
    const labels = capture(&players, .{ .observation = .{ .raw = .{ .units = &units } } }, .{ .width = 100, .height = 200 });
    players[0].name[0] = 'X';
    try std.testing.expectEqual(@as(usize, 2), labels.count);
    try std.testing.expectEqualStrings("Maru", std.mem.sliceTo(&labels.items[0].name, 0));
    try std.testing.expectApproxEqAbs(@as(f32, 0.35), labels.items[0].x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), labels.items[1].y, 0.001);
    try std.testing.expectEqual(@as(usize, 0), capture(&players, .{}, .{ .width = 100, .height = 200 }).count);
}
