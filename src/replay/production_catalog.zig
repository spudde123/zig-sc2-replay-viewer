//! Startup-only game-data lookup; products copied into each owned order snapshot.
const std = @import("std");
const p = @import("zig-sc2").sc2p;
const data = @import("replay_data.zig");
const Entry = struct { ability: u32, product: data.Product };

pub fn setName(product: *data.Product, source: []const u8) void {
    const n = @min(source.len, product.name.len);
    @memcpy(product.name[0..n], source[0..n]);
    for (product.name[0..n]) |*byte| if (byte.* < 32 or byte.* > 126) {
        byte.* = '?';
    };
    if (source.len > n and n >= 3) @memcpy(product.name[n - 3 .. n], "...");
}

fn abilityName(id: u32) ?[]const u8 {
    return std.enums.tagName(@FieldType(p.UnitOrder, "ability_id"), @fromBackingInt(id));
}
fn contains(value: []const u8, part: []const u8) bool {
    return std.mem.indexOf(u8, value, part) != null;
}
fn excluded(name: []const u8) bool {
    // Mode changes and worker build commands are not additional production.
    // Structures/add-ons are represented by their own build_progress instead.
    if (contains(name, "Cancel")) return true;
    // Research_Burrow and TerranBuildingArmor are upgrades, not mode/build commands.
    if (contains(name, "Research")) return false;
    return contains(name, "Build") or contains(name, "Burrow") or
        contains(name, "SiegeMode") or contains(name, "Unsiege") or contains(name, "Lift") or contains(name, "Land") or
        (contains(name, "Morph") and (contains(name, "Viking") or contains(name, "Hellion") or
            contains(name, "Hellbat") or contains(name, "SupplyDepot_") or contains(name, "Liberator") or
            contains(name, "OverseerMode") or contains(name, "Oversight")));
}

pub const Catalog = struct {
    storage: []Entry = &.{},
    count: usize = 0,

    pub fn init(allocator: std.mem.Allocator, response: p.ResponseData) !Catalog {
        const units = response.units orelse &.{};
        const upgrades = response.upgrades orelse &.{};
        var self: Catalog = .{ .storage = try allocator.alloc(Entry, units.len + upgrades.len) };
        for (units) |unit| {
            const id = unit.unit_id orelse continue;
            const ability = unit.ability_id orelse continue;
            if (ability == 0) continue;
            const name = abilityName(ability) orelse "";
            if (excluded(name)) continue;
            const morph = contains(name, "Morph") or contains(name, "UpgradeTo");
            var structure = false;
            for (unit.attributes orelse &.{}) |attribute| if (attribute == .structure) {
                structure = true;
            };
            if (structure and !morph) continue;
            var product: data.Product = .{ .key = id, .kind = .unit, .replaces_construction = morph };
            setName(&product, unit.name orelse std.enums.tagName(@FieldType(p.Unit, "unit_type"), @fromBackingInt(id)) orelse "Unknown unit");
            self.storage[self.count] = .{ .ability = ability, .product = product };
            self.count += 1;
        }
        for (upgrades) |upgrade| {
            const id = upgrade.upgrade_id orelse continue;
            const ability = upgrade.ability_id orelse continue;
            if (ability == 0) continue;
            var product: data.Product = .{ .key = id, .kind = .research };
            setName(&product, upgrade.name orelse "Unknown upgrade");
            self.storage[self.count] = .{ .ability = ability, .product = product };
            self.count += 1;
        }
        std.mem.sort(Entry, self.storage[0..self.count], {}, struct {
            fn less(_: void, a: Entry, b: Entry) bool {
                if (a.ability != b.ability) return a.ability < b.ability;
                return a.product.key < b.product.key;
            }
        }.less);
        return self;
    }

    pub fn deinit(self: Catalog, allocator: std.mem.Allocator) void {
        allocator.free(self.storage);
    }

    pub fn find(self: *const Catalog, ability: u32) ?data.Product {
        var lo: usize = 0;
        var hi = self.count;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.storage[mid].ability < ability) lo = mid + 1 else hi = mid;
        }
        if (lo < self.count and self.storage[lo].ability == ability) return self.storage[lo].product;
        const name = abilityName(ability) orelse return null;
        if (excluded(name)) return null;
        const research = contains(name, "Research");
        const morph = contains(name, "Morph") or contains(name, "UpgradeTo");
        if (!research and !morph and !contains(name, "Train")) return null;
        // Separate fallback ability IDs from known result type/upgrade IDs.
        var product: data.Product = .{ .key = (@as(u64, 1) << 32) | ability, .kind = if (research) .research else .unit, .replaces_construction = morph };
        var label = name;
        for ([_][]const u8{ "Research_", "Train_", "TrainWarp_", "Morph_" }) |prefix| {
            if (std.mem.startsWith(u8, label, prefix)) {
                label = label[prefix.len..];
                break;
            }
        }
        setName(&product, label);
        return product;
    }
};

test "catalog owns unit and research names, ignores builds and mode changes, and falls back safely" {
    var name = [_]u8{ 'S', 'C', 'V' };
    var attributes = [_]p.Attribute{.structure};
    var units = [_]p.UnitTypeData{
        .{ .unit_id = 45, .ability_id = 524, .name = &name },
        .{ .unit_id = 100, .ability_id = 1216, .name = "Lair", .attributes = &attributes },
    };
    var upgrades = [_]p.UpgradeData{.{ .upgrade_id = 7, .ability_id = 652, .name = "Infantry weapons 1" }};
    const catalog = try Catalog.init(std.testing.allocator, .{ .units = &units, .upgrades = &upgrades });
    defer catalog.deinit(std.testing.allocator);
    name[0] = 'X';
    try std.testing.expectEqualStrings("SCV", std.mem.sliceTo(&catalog.find(524).?.name, 0));
    try std.testing.expectEqual(data.Product.Kind.research, catalog.find(652).?.kind);
    try std.testing.expectEqualStrings("Infantry weapons 1", std.mem.sliceTo(&catalog.find(652).?.name, 0));
    try std.testing.expect(catalog.find(16) == null);
    try std.testing.expect(catalog.find(556) == null);
    try std.testing.expect(catalog.find(319) == null); // SCV build SupplyDepot
    try std.testing.expect(catalog.find(99999) == null);
    try std.testing.expect(catalog.find(216).?.kind == .research);
    try std.testing.expect(catalog.find(595).?.kind == .unit); // Hellion training is not a mode change
    try std.testing.expect(catalog.find(624).?.kind == .unit); // Viking training
    try std.testing.expect(catalog.find(626).?.kind == .unit); // Liberator training
    try std.testing.expectEqual(@as(u64, 100), catalog.find(1216).?.key);
    try std.testing.expect(catalog.find(1216).?.replaces_construction);
    try std.testing.expect(catalog.find(1516).?.replaces_construction); // Orbital fallback
    try std.testing.expect(catalog.find(1225).?.kind == .research); // Burrow research fallback
}
