//! Converts borrowed protocol observations into renderer-independent owned data.
const std = @import("std");
const p = @import("zig-sc2").sc2p;
const data = @import("replay_data.zig");

pub const Terrain = struct {
    width: usize,
    height: usize,
    bytes: []u8,

    pub fn copy(allocator: std.mem.Allocator, image: p.ImageData) !Terrain {
        const size = image.size orelse return error.MissingTerrainSize;
        const w = size.x orelse return error.MissingTerrainSize;
        const h = size.y orelse return error.MissingTerrainSize;
        if (w <= 0 or h <= 0 or w > 4096 or h > 4096 or image.bits_per_pixel != 8) return error.InvalidTerrain;
        const bytes = image.image orelse return error.InvalidTerrain;
        if (bytes.len != @as(usize, @intCast(w)) * @as(usize, @intCast(h))) return error.InvalidTerrain;
        return .{ .width = @intCast(w), .height = @intCast(h), .bytes = try allocator.dupe(u8, bytes) };
    }

    pub fn deinit(self: Terrain, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
    }

    /// Raw terrain rows have bottom-left world origin, unlike the RGB image.
    pub fn sample(self: Terrain, x: f32, y: f32) ?f32 {
        if (!std.math.isFinite(x) or !std.math.isFinite(y) or x < 0 or y < 0 or
            x >= @as(f32, @floatFromInt(self.width)) or y >= @as(f32, @floatFromInt(self.height))) return null;
        const ix: usize = @intFromFloat(@floor(x));
        const iy: usize = @intFromFloat(@floor(y));
        return -16 + 32 * @as(f32, @floatFromInt(self.bytes[ix + iy * self.width])) / 255;
    }
};

pub const Context = struct {
    camera: ?struct { x: f32, y: f32, distance: f32 } = null,
    terrain: ?*const Terrain = null,
    production_catalog: ?*const @import("production_catalog.zig").Catalog = null,
};

fn name(destination: []u8, source: ?[]const u8, id: u32) void {
    @memset(destination, 0);
    if (source) |s| {
        const n = @min(destination.len - 1, s.len);
        @memcpy(destination[0..n], s[0..n]);
        if (s.len > n and n >= 3) @memcpy(destination[n - 3 .. n], "...");
    } else _ = std.fmt.bufPrint(destination[0 .. destination.len - 1], "ID {d}", .{id}) catch unreachable;
}

pub fn capture(allocator: std.mem.Allocator, raw: ?p.ObservationRaw, context: Context) !data.Scene {
    var result: data.Scene = .{};
    if (context.camera) |camera| {
        if (context.terrain) |terrain| {
            if (terrain.sample(camera.x, camera.y)) |z| {
                result.camera = .{ .target = .{ .x = camera.x, .y = camera.y, .z = z }, .distance = camera.distance };
            }
        }
    }
    const observation = raw orelse return result;
    if (observation.player) |player| {
        if (player.camera) |camera| result.reported_camera = .{ .x = camera.x, .y = camera.y, .z = camera.z };
    }
    var order_count: usize = 0;
    for (observation.units) |unit| order_count = try std.math.add(usize, order_count, unit.orders.len);
    result.units = try allocator.alloc(data.Unit, observation.units.len);
    errdefer allocator.free(result.units);
    result.orders = try allocator.alloc(data.Order, order_count);
    var cursor: usize = 0;
    for (observation.units, result.units) |unit, *copy| {
        copy.* = .{
            .tag = unit.tag,
            .type_id = @intCast(@backingInt(unit.unit_type)),
            .owner = unit.owner,
            .position = .{ .x = unit.position.x, .y = unit.position.y, .z = unit.z },
            .radius = unit.radius,
            .visible = unit.display_type == .visible and !unit.is_blip,
            .flying = unit.is_flying,
            .build_progress = unit.build_progress,
            .health = unit.health,
            .health_max = unit.health_max,
            .shield = unit.shield,
            .shield_max = unit.shield_max,
            .energy = unit.energy,
            .energy_max = unit.energy_max,
            .mineral_contents = unit.mineral_contents,
            .vespene_contents = unit.vespene_contents,
            .assigned_harvesters = unit.assigned_harvesters,
            .ideal_harvesters = unit.ideal_harvesters,
            .order_start = cursor,
            .order_count = unit.orders.len,
        };
        // is_on_screen belongs to SC2's raw camera, which can differ from the
        // replay observer RGB camera. Do not use it to cull our projected units.
        name(&copy.name, std.enums.tagName(@TypeOf(unit.unit_type), unit.unit_type), copy.type_id);
        for (unit.orders) |order| {
            const id: u32 = @intCast(@backingInt(order.ability_id));
            var target: data.Order.Target = .none;
            switch (order.target) {
                .empty => {},
                .tag => |tag| target = .{ .unit = tag },
                .position => |point| {
                    // Point orders may contain zero/default Z even on elevated
                    // ground. Prefer terrain for ground destinations in that case.
                    var z = order.target_z;
                    if (z == null or z.? == 0) {
                        if (context.terrain) |terrain| z = terrain.sample(point.x, point.y);
                    }
                    target = .{ .position = .{ .x = point.x, .y = point.y, .z = z } };
                },
            }
            result.orders[cursor] = .{ .ability_id = id, .progress = order.progress, .target = target, .product = if (context.production_catalog) |catalog| catalog.find(id) else null };
            name(&result.orders[cursor].name, std.enums.tagName(@TypeOf(order.ability_id), order.ability_id), id);
            cursor += 1;
        }
    }
    // Binary tag lookup remains valid when raw unit ordering changes each step.
    std.mem.sort(data.Unit, result.units, {}, struct {
        fn less(_: void, a: data.Unit, b: data.Unit) bool {
            return a.tag < b.tag;
        }
    }.less);
    return result;
}

test "scene owns flattened orders, names and neutral targets after response reuse" {
    var orders = [_]p.UnitOrder{
        .{ .ability_id = @fromBackingInt(16), .target = .{ .position = .{ .x = 1, .y = 1 } } },
        .{ .ability_id = @fromBackingInt(295), .target = .{ .tag = 10 } },
    };
    var units = [_]p.Unit{
        .{ .tag = 20, .owner = 1, .unit_type = @fromBackingInt(45), .position = .{ .x = 1, .y = 1 }, .z = 12, .orders = &orders },
        .{ .tag = 10, .owner = 16, .position = .{ .x = 2, .y = 1 }, .z = 12 },
    };
    var bytes: [4]u8 = @splat(223);
    const terrain: Terrain = .{ .width = 2, .height = 2, .bytes = &bytes };
    const scene = try capture(std.testing.allocator, .{ .units = &units }, .{ .camera = .{ .x = 1, .y = 1, .distance = 40 }, .terrain = &terrain });
    defer scene.deinit(std.testing.allocator);
    orders[1].target = .empty;
    units[0].position.x = 99;
    const selected = scene.find(20).?;
    try std.testing.expectEqual(@as(f32, 1), selected.position.x);
    try std.testing.expectEqual(@as(u64, 10), scene.ordersFor(selected)[1].target.unit);
    try std.testing.expectEqual(@as(i32, 16), scene.find(10).?.owner);
    try std.testing.expectEqualStrings("SCV", std.mem.sliceTo(&selected.name, 0));
    try std.testing.expectApproxEqAbs(@as(f32, 11.984314), scene.ordersFor(selected)[0].target.position.z.?, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 11.984314), scene.camera.?.target.z, 0.001);
    try std.testing.expect(scene.find(999) == null);
}

test "production products survive response arena and catalog destruction" {
    const Catalog = @import("production_catalog.zig").Catalog;
    var unit_types = [_]p.UnitTypeData{.{ .unit_id = 45, .ability_id = 524, .name = "SCV" }};
    var upgrades = [_]p.UpgradeData{.{ .upgrade_id = 7, .ability_id = 652, .name = "InfantryWeapons1" }};
    const catalog = try Catalog.init(std.testing.allocator, .{ .units = &unit_types, .upgrades = &upgrades });
    var orders = [_]p.UnitOrder{
        .{ .ability_id = @fromBackingInt(524), .progress = 0.5 },
        .{ .ability_id = @fromBackingInt(652), .progress = 0.25 },
    };
    var units = [_]p.Unit{.{ .tag = 20, .build_progress = 0.75, .orders = &orders }};
    const scene = capture(std.testing.allocator, .{ .units = &units }, .{ .production_catalog = &catalog }) catch |err| {
        catalog.deinit(std.testing.allocator);
        return err;
    };
    catalog.deinit(std.testing.allocator);
    defer scene.deinit(std.testing.allocator);
    orders[0] = .{};
    units[0] = .{};
    const copied = scene.ordersFor(scene.find(20).?);
    try std.testing.expectEqualStrings("SCV", std.mem.sliceTo(&copied[0].product.?.name, 0));
    try std.testing.expect(copied[1].product.?.kind == .research);
    try std.testing.expectEqualStrings("InfantryWeapons1", std.mem.sliceTo(&copied[1].product.?.name, 0));
    try std.testing.expectEqual(@as(f32, 0.75), scene.find(20).?.build_progress);
}

test "unit vitals, resources and harvester counts survive response reuse" {
    const expected: p.Unit = .{ .tag = 20, .build_progress = 0.5, .health = 75, .health_max = 100, .shield = 25, .shield_max = 50, .energy = 0, .energy_max = 200, .mineral_contents = 1500, .vespene_contents = 2250, .assigned_harvesters = 2, .ideal_harvesters = 3 };
    var units = [_]p.Unit{expected};
    const scene = try capture(std.testing.allocator, .{ .units = &units }, .{});
    defer scene.deinit(std.testing.allocator);
    units[0] = .{};
    const selected = scene.find(20).?;
    inline for (.{ "build_progress", "health", "health_max", "shield", "shield_max", "energy", "energy_max", "mineral_contents", "vespene_contents", "assigned_harvesters", "ideal_harvesters" }) |field| {
        try std.testing.expectEqual(@field(expected, field), @field(selected.*, field));
    }
}

test "terrain sampling validates bounds, bottom-left rows and owns bytes" {
    var bytes = [_]u8{ 0, 127, 223, 255 };
    const terrain = try Terrain.copy(std.testing.allocator, .{ .size = .{ .x = 2, .y = 2 }, .bits_per_pixel = 8, .image = &bytes });
    defer terrain.deinit(std.testing.allocator);
    bytes[0] = 255;
    try std.testing.expectEqual(@as(f32, -16), terrain.sample(0, 0).?);
    try std.testing.expectEqual(@as(f32, 16), terrain.sample(1, 1).?);
    try std.testing.expect(terrain.sample(2, 0) == null);
    try std.testing.expect(terrain.sample(-1, 0) == null);
    try std.testing.expect(terrain.sample(std.math.nan(f32), 0) == null);
}
