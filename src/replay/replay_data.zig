//! Value-owned data crossing the game/GUI boundary. No protocol or renderer types.
//! Chat is an event stream (FIFO); Scene is replaceable state attached to the
//! matching image frame. All slices in a Scene are owned, never response pointers.
const std = @import("std");

pub const Vec3 = struct { x: f32 = 0, y: f32 = 0, z: f32 = 0 };

pub const CameraPose = struct {
    // Observer command target, with terrain elevation (not camera eye position).
    target: Vec3,
    distance: f32,
};

pub const Product = struct {
    pub const Kind = enum { unit, research };
    key: u64,
    kind: Kind,
    name: [49:0]u8 = @splat(0),
    replaces_construction: bool = false,
};

pub const Unit = struct {
    tag: u64,
    type_id: u32,
    name: [49:0]u8 = @splat(0),
    owner: i32,
    position: Vec3,
    radius: f32,
    visible: bool,
    flying: bool,
    build_progress: f32 = 0,
    health: f32 = 0,
    health_max: f32 = 0,
    shield: f32 = 0,
    shield_max: f32 = 0,
    energy: f32 = 0,
    energy_max: f32 = 0,
    mineral_contents: i32 = 0,
    vespene_contents: i32 = 0,
    assigned_harvesters: i32 = 0,
    ideal_harvesters: i32 = 0,
    attack_upgrade_level: i32 = 0,
    armor_upgrade_level: i32 = 0,
    shield_upgrade_level: i32 = 0,
    order_start: usize,
    order_count: usize,
};

pub const Order = struct {
    pub const Target = union(enum) {
        none,
        position: struct { x: f32, y: f32, z: ?f32 },
        unit: u64,
    };
    ability_id: u32,
    product: ?Product = null,
    name: [49:0]u8 = @splat(0),
    progress: f32,
    target: Target,
};

pub const Scene = struct {
    camera: ?CameraPose = null,
    // Retained for diagnostics, not assumed to be the observer RGB camera.
    reported_camera: ?Vec3 = null,
    units: []Unit = &.{},
    orders: []Order = &.{},

    pub fn deinit(self: Scene, allocator: std.mem.Allocator) void {
        allocator.free(self.units);
        allocator.free(self.orders);
    }

    pub fn find(self: *const Scene, tag: u64) ?*const Unit {
        var lo: usize = 0;
        var hi = self.units.len;
        while (lo < hi) {
            const middle = lo + (hi - lo) / 2;
            const unit = &self.units[middle];
            if (unit.tag == tag) return unit;
            if (unit.tag < tag) lo = middle + 1 else hi = middle;
        }
        return null;
    }

    pub fn ordersFor(self: *const Scene, unit: *const Unit) []const Order {
        return self.orders[unit.order_start .. unit.order_start + unit.order_count];
    }

    pub fn targetPosition(self: *const Scene, order: Order) ?Vec3 {
        return switch (order.target) {
            .none => null,
            .position => |p| if (p.z) |z| .{ .x = p.x, .y = p.y, .z = z } else null,
            .unit => |tag| if (self.find(tag)) |unit| (if (unit.visible) unit.position else null) else null,
        };
    }
};

pub const PlayerEconomy = struct {
    game_loop: u32,
    minerals: u32,
    vespene: u32,
    food_used: f32,
    food_cap: f32,
    worker_supply: u32,
    // Total used supply minus existing workers, including reserved production supply.
    army_supply: f32,
};

pub const PlayerStats = struct {
    available: bool = false,
    items: [16]?PlayerEconomy = @splat(null),
};

pub const Players = struct {
    pub const Player = struct {
        id: u32 = 0,
        name: [32]u8 = @splat(0),
        name_len: usize = 0,
    };
    items: [16]Player = @splat(.{}),
    count: usize = 0,

    pub fn add(self: *Players, id: u32, player_name: []const u8) void {
        if (self.count == self.items.len) return;
        var player: Player = .{ .id = id };
        player.name_len = @min(player_name.len, player.name.len);
        @memcpy(player.name[0..player.name_len], player_name[0..player.name_len]);
        self.items[self.count] = player;
        self.count += 1;
    }

    pub fn name(self: *const Players, id: u32) ?[]const u8 {
        for (self.items[0..self.count]) |*player| {
            if (player.id != id) continue;
            const value = std.mem.trim(u8, player.name[0..player.name_len], " \t\r\n");
            return if (value.len > 0) value else null;
        }
        return null;
    }
};

pub const ChatMessage = struct {
    pub const max_bytes = 512;
    player_id: u32 = 0,
    // Delivery observation's loop, not the original event timestamp.
    game_loop: u32 = 0,
    bytes: [max_bytes]u8 = @splat(0),
    len: usize = 0,
    truncated: bool = false,

    pub fn init(player_id: u32, game_loop: u32, message: []const u8) ChatMessage {
        var result: ChatMessage = .{ .player_id = player_id, .game_loop = game_loop };
        result.len = @min(message.len, result.bytes.len);
        result.truncated = message.len > result.bytes.len;
        if (result.truncated) {
            // Avoid cutting a valid UTF-8 codepoint in half at the byte limit.
            while (result.len > 0 and message[result.len] & 0xc0 == 0x80) result.len -= 1;
        }
        @memcpy(result.bytes[0..result.len], message[0..result.len]);
        return result;
    }

    pub fn text(self: *const ChatMessage) []const u8 {
        return self.bytes[0..self.len];
    }
};

/// Used both for the worker's pending events and the GUI's recent history.
/// Overflow retains the newest messages; omitted-message counts survive transfer.
/// Synchronization is owned by the caller (worker mutex / GUI thread).
pub const ChatQueue = struct {
    pub const capacity = 128;
    items: [capacity]ChatMessage = @splat(.{}),
    head: usize = 0,
    count: usize = 0,
    omitted: u64 = 0,

    pub fn push(self: *ChatQueue, message: ChatMessage) void {
        if (self.count == capacity) {
            self.head = (self.head + 1) % capacity;
            self.count -= 1;
            self.omitted += 1;
        }
        self.items[(self.head + self.count) % capacity] = message;
        self.count += 1;
    }

    pub fn at(self: *const ChatQueue, index: usize) *const ChatMessage {
        std.debug.assert(index < self.count);
        return &self.items[(self.head + index) % capacity];
    }

    pub fn pop(self: *ChatQueue) ?ChatMessage {
        if (self.count == 0) return null;
        const message = self.items[self.head];
        self.head = (self.head + 1) % capacity;
        self.count -= 1;
        return message;
    }

    pub fn drainInto(self: *ChatQueue, destination: *ChatQueue) void {
        std.debug.assert(self != destination);
        destination.omitted += self.omitted;
        self.omitted = 0;
        while (self.pop()) |message| destination.push(message);
    }
};

test "chat and player names own their bytes and long messages are bounded" {
    var original = [_]u8{ 'g', 'l', 'h', 'f' };
    const message = ChatMessage.init(2, 224, &original);
    var players: Players = .{};
    players.add(2, &original);
    original[0] = 'X';
    try std.testing.expectEqualStrings("glhf", message.text());
    try std.testing.expectEqualStrings("glhf", players.name(2).?);
    try std.testing.expect(players.name(3) == null);
    players.add(3, " \t");
    try std.testing.expect(players.name(3) == null);
    const long: [600]u8 = @splat('x');
    const bounded = ChatMessage.init(1, 0, &long);
    try std.testing.expectEqual(@as(usize, 512), bounded.len);
    try std.testing.expect(bounded.truncated);
    var unicode: [514]u8 = @splat('x');
    @memcpy(unicode[511..514], "€");
    const clipped = ChatMessage.init(1, 0, &unicode);
    try std.testing.expectEqual(@as(usize, 511), clipped.len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(clipped.text()));
}

test "chat FIFO survives draining independently of replaced frames and reports overflow" {
    var pending: ChatQueue = .{};
    var history: ChatQueue = .{};
    for (0..ChatQueue.capacity + 2) |i| pending.push(ChatMessage.init(1, @intCast(i), "hello"));
    try std.testing.expectEqual(@as(u64, 2), pending.omitted);
    pending.drainInto(&history);
    try std.testing.expectEqual(@as(usize, 0), pending.count);
    try std.testing.expectEqual(@as(u64, 0), pending.omitted);
    try std.testing.expectEqual(@as(u64, 2), history.omitted);
    try std.testing.expectEqual(@as(u32, 2), history.at(0).game_loop);
    try std.testing.expectEqual(@as(u32, 129), history.at(history.count - 1).game_loop);
    pending.drainInto(&history);
    try std.testing.expectEqual(@as(u64, 2), history.omitted);
    history.push(ChatMessage.init(2, 130, "next"));
    try std.testing.expectEqual(@as(u64, 3), history.omitted);
    try std.testing.expectEqual(@as(u32, 3), history.pop().?.game_loop);
}
