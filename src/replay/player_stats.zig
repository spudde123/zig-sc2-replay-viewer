//! Economy samples and timestamped unit deaths from the build-75689 tracker.
//! Narrow replay reader: MPQ v3 single-unit tracker file and
//! Blizzard's versioned tracker encoding. Not a general-purpose replay parser.
//! Format/algorithm references: mpyq (BSD-2-Clause), s2protocol (MIT).
//! Notices are in licenses/mpyq.txt and licenses/s2protocol.txt.
const std = @import("std");
const data = @import("replay_data.zig");
const losses = @import("losses.zig");
const max_file = 64 * 1024 * 1024;
const max_tracker = 16 * 1024 * 1024;

pub const Sample = struct { player_id: u8, values: data.PlayerEconomy };
pub const Timeline = struct {
    samples: []Sample,
    deaths: []losses.Death = &.{},
    pub fn deinit(self: Timeline, allocator: std.mem.Allocator) void {
        allocator.free(self.samples);
        allocator.free(self.deaths);
    }
    pub fn at(self: Timeline, loop: u32, players: *const data.Players) data.PlayerStats {
        var result: data.PlayerStats = .{ .available = true };
        for (players.items[0..players.count], 0..) |player, slot| result.player_ids[slot] = player.id;
        var lo: usize = 0;
        var hi = self.samples.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.samples[mid].values.game_loop <= loop) lo = mid + 1 else hi = mid;
        }
        var remaining = players.count;
        while (lo > 0 and remaining > 0) {
            lo -= 1;
            const sample = self.samples[lo];
            const slot = players.slotForId(sample.player_id) orelse continue;
            if (result.items[slot] == null) {
                result.items[slot] = sample.values;
                remaining -= 1;
            }
        }
        return result;
    }
};

test "timeline selects preceding complete supply samples independently for each player" {
    var samples = [_]Sample{
        .{ .player_id = 1, .values = .{ .game_loop = 1, .minerals = 50, .vespene = 0, .food_used = 12, .food_cap = 15, .worker_supply = 12 } },
        .{ .player_id = 2, .values = .{ .game_loop = 10, .minerals = 100, .vespene = 25, .food_used = 13.5, .food_cap = 20, .worker_supply = 12 } },
        .{ .player_id = 1, .values = .{ .game_loop = 160, .minerals = 200, .vespene = 50, .food_used = 50, .food_cap = 60, .worker_supply = 20 } },
    };
    // Deliberately reverse metadata order and use noncontiguous protocol IDs.
    samples[0].player_id = 3;
    samples[1].player_id = 7;
    samples[2].player_id = 3;
    var players: data.Players = .{};
    players.add(7, "Bob");
    players.add(3, "Alice");
    const timeline: Timeline = .{ .samples = &samples };
    try std.testing.expect(timeline.at(0, &players).forPlayer(3) == null);
    try std.testing.expect(timeline.at(1, &players).forPlayer(7) == null);
    try std.testing.expectEqualDeep(samples[0].values, timeline.at(159, &players).forPlayer(3).?);
    try std.testing.expectEqualDeep(samples[1].values, timeline.at(160, &players).items[0].?);
    try std.testing.expectEqualDeep(samples[2].values, timeline.at(160, &players).items[1].?);
    try std.testing.expectEqualDeep(samples[0].values, timeline.at(1, &players).forPlayer(3).?);
    try std.testing.expect(timeline.at(160, &players).forPlayer(1) == null);
}

pub fn load(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Timeline {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_file));
    defer allocator.free(bytes);
    return parse(allocator, bytes);
}

fn range(bytes: []const u8, offset: usize, size: usize) ![]const u8 {
    if (offset > bytes.len or size > bytes.len - offset) return error.TruncatedReplay;
    return bytes[offset..][0..size];
}
fn le32(bytes: []const u8, offset: usize) !u32 {
    return std.mem.readInt(u32, (try range(bytes, offset, 4))[0..4], .little);
}
fn le16(bytes: []const u8, offset: usize) !u16 {
    return std.mem.readInt(u16, (try range(bytes, offset, 2))[0..2], .little);
}

const crypt_table = blk: {
    @setEvalBranchQuota(20000);
    var table: [1280]u32 = undefined;
    var seed: u64 = 0x100001;
    for (0..256) |i| for (0..5) |j| {
        seed = (seed * 125 + 3) % 0x2aaaab;
        const high: u32 = @intCast((seed & 0xffff) << 16);
        seed = (seed * 125 + 3) % 0x2aaaab;
        table[i + j * 256] = high | @as(u32, @intCast(seed & 0xffff));
    };
    break :blk table;
};
fn hash(name: []const u8, kind: usize) u32 {
    var a: u32 = 0x7fed7fed;
    var b: u32 = 0xeeeeeeee;
    for (name) |ch| {
        const c = std.ascii.toUpper(ch);
        a = crypt_table[kind * 256 + c] ^ (a +% b);
        b = @as(u32, c) +% a +% b +% (b << 5) +% 3;
    }
    return a;
}
fn decrypt(allocator: std.mem.Allocator, bytes: []const u8, key: u32) ![]u8 {
    const result = try allocator.dupe(u8, bytes);
    var a = key;
    var b: u32 = 0xeeeeeeee;
    var i: usize = 0;
    while (i < result.len) : (i += 4) {
        b +%= crypt_table[1024 + (a & 255)];
        const value = std.mem.readInt(u32, result[i..][0..4], .little) ^ (a +% b);
        std.mem.writeInt(u32, result[i..][0..4], value, .little);
        a = ((~a << 21) +% 0x11111111) | (a >> 11);
        b = value +% b +% (b << 5) +% 3;
    }
    return result;
}

fn openBzip2(names: []const []const u8) !std.DynLib {
    for (names) |name| return std.DynLib.open(name) catch continue;
    return error.Bzip2LibraryUnavailable;
}

fn decompress(allocator: std.mem.Allocator, bytes: []const u8, size: usize) ![]u8 {
    if (bytes.len < 2 or bytes[0] != 0x10) return error.UnsupportedCompression;
    const Fn = *const fn ([*]u8, *c_uint, [*]const u8, c_uint, c_int, c_int) callconv(.c) c_int;
    var lib = try openBzip2(&.{ "libbz2.so.1", "libbz2.so.1.0", "libbz2.so" });
    defer lib.close();
    const function = lib.lookup(Fn, "BZ2_bzBuffToBuffDecompress") orelse return error.Bzip2LibraryUnavailable;
    const result = try allocator.alloc(u8, size);
    errdefer allocator.free(result);
    var length: c_uint = @intCast(size);
    if (function(result.ptr, &length, bytes[1..].ptr, @intCast(bytes.len - 1), 0, 0) != 0 or length != size)
        return error.InvalidCompressedTracker;
    return result;
}

fn extract(allocator: std.mem.Allocator, bytes: []const u8, base: usize) ![]u8 {
    const header = try range(bytes, base, 208);
    if (!std.mem.eql(u8, header[0..4], "MPQ\x1a") or try le16(header, 12) != 3 or try le32(header, 4) != 208)
        return error.UnsupportedArchive;
    // Only the low-offset, uncompressed classic tables used by these replays.
    const high_offsets: [12]u8 = @splat(0);
    if (!std.mem.eql(u8, header[32..44], &high_offsets)) return error.UnsupportedArchive;
    const hash_count = try le32(header, 24);
    const block_count = try le32(header, 28);
    if (hash_count == 0 or block_count == 0 or hash_count > 65536 or block_count > 65536) return error.InvalidArchive;
    const hashes = try decrypt(allocator, try range(bytes, base + @as(usize, try le32(header, 16)), @as(usize, hash_count) * 16), hash("(hash table)", 3));
    defer allocator.free(hashes);
    const blocks = try decrypt(allocator, try range(bytes, base + @as(usize, try le32(header, 20)), @as(usize, block_count) * 16), hash("(block table)", 3));
    defer allocator.free(blocks);
    const a = hash("replay.tracker.events", 1);
    const b = hash("replay.tracker.events", 2);
    for (0..hash_count) |i| {
        const entry = hashes[i * 16 ..][0..16];
        if (try le32(entry, 0) != a or try le32(entry, 4) != b) continue;
        const index = try le32(entry, 12);
        if (index >= block_count) return error.InvalidArchive;
        const block = blocks[@as(usize, index) * 16 ..][0..16];
        const compressed_size = try le32(block, 4);
        const size = try le32(block, 8);
        const flags = try le32(block, 12);
        if (flags & 0x81000000 != 0x81000000 or flags & ~@as(u32, 0x81000200) != 0) return error.UnsupportedArchive;
        if (size == 0 or size > max_tracker or compressed_size > max_file) return error.InvalidArchive;
        const contents = try range(bytes, base + @as(usize, try le32(block, 0)), compressed_size);
        if (compressed_size == size) return allocator.dupe(u8, contents);
        if (compressed_size > size or flags & 0x200 == 0) return error.InvalidArchive;
        return decompress(allocator, contents, size);
    }
    return error.MissingTrackerEvents;
}

const Reader = struct {
    bytes: []const u8,
    pos: usize = 0,
    fn take(self: *Reader, n: usize) ![]const u8 {
        const value = try range(self.bytes, self.pos, n);
        self.pos += n;
        return value;
    }
    fn byte(self: *Reader) !u8 {
        return (try self.take(1))[0];
    }
    fn expect(self: *Reader, tag: u8) !void {
        if (try self.byte() != tag) return error.InvalidTrackerEncoding;
    }
    fn vint(self: *Reader) !i64 {
        var b = try self.byte();
        const negative = b & 1 != 0;
        var value: u64 = (b >> 1) & 63;
        var shift: u7 = 6;
        while (b & 128 != 0) {
            b = try self.byte();
            if (shift > 62 or @as(u64, b & 127) > @as(u64, std.math.maxInt(i64)) >> @as(u6, @intCast(shift))) return error.InvalidTrackerEncoding;
            value |= @as(u64, b & 127) << @as(u6, @intCast(shift));
            shift += 7;
        }
        const number: i64 = @intCast(value);
        return if (negative) -number else number;
    }
    fn count(self: *Reader) !usize {
        const n = try self.vint();
        if (n < 0 or n > self.bytes.len - self.pos) return error.InvalidTrackerEncoding;
        return @intCast(n);
    }
    fn integer(self: *Reader) !u32 {
        try self.expect(9);
        const value = try self.vint();
        if (value < 0 or value > std.math.maxInt(u32)) return error.InvalidTrackerEncoding;
        return @intCast(value);
    }
    fn signedInteger(self: *Reader) !i32 {
        try self.expect(9);
        const value = try self.vint();
        if (value < std.math.minInt(i32) or value > std.math.maxInt(i32)) return error.InvalidTrackerEncoding;
        return @intCast(value);
    }
    fn name(self: *Reader) !losses.Name {
        try self.expect(2);
        const n = try self.count();
        const bytes = try self.take(n);
        var result: losses.Name = @splat(0);
        const length = @min(bytes.len, result.len);
        @memcpy(result[0..length], bytes[0..length]);
        for (result[0..length]) |*ch| if (ch.* < 32 or ch.* > 126) {
            ch.* = '?';
        };
        if (n > result.len) @memcpy(result[result.len - 3 ..], "...");
        return result;
    }
    fn structure(self: *Reader) !usize {
        try self.expect(5);
        return self.count();
    }
    fn skip(self: *Reader, depth: usize) !void {
        if (depth > 32) return error.InvalidTrackerEncoding;
        switch (try self.byte()) {
            0 => {
                const n = try self.count();
                for (0..n) |_| try self.skip(depth + 1);
            },
            1 => {
                const n = try self.vint();
                if (n < 0 or n > max_tracker * 8) return error.InvalidTrackerEncoding;
                _ = try self.take((@as(usize, @intCast(n)) + 7) / 8);
            },
            2 => {
                const n = try self.count();
                _ = try self.take(n);
            },
            3 => {
                _ = try self.vint();
                try self.skip(depth + 1);
            },
            4 => {
                const present = try self.byte();
                if (present > 1) return error.InvalidTrackerEncoding;
                if (present != 0) try self.skip(depth + 1);
            },
            5 => {
                const n = try self.count();
                for (0..n) |_| {
                    _ = try self.vint();
                    try self.skip(depth + 1);
                }
            },
            6 => {
                _ = try self.take(1);
            },
            7 => {
                _ = try self.take(4);
            },
            8 => {
                _ = try self.take(8);
            },
            9 => {
                _ = try self.vint();
            },
            else => return error.InvalidTrackerEncoding,
        }
    }
};

fn checkBuild(bytes: []const u8) !void {
    var reader: Reader = .{ .bytes = bytes };
    var build: ?u32 = null;
    const fields = try reader.structure();
    for (0..fields) |_| {
        if (try reader.vint() == 1) {
            const version_fields = try reader.structure();
            for (0..version_fields) |_| {
                if (try reader.vint() == 5) build = try reader.integer() else try reader.skip(0);
            }
        } else try reader.skip(0);
    }
    if (build != 75689) return error.UnsupportedReplayBuild;
    if (reader.pos != bytes.len) return error.InvalidTrackerEncoding;
}

fn readSample(reader: *Reader, loop: u32) !Sample {
    var player: ?u32 = null;
    var values: [5]?u32 = @splat(null);
    var lost: [6]?i32 = @splat(null);
    const fields = try reader.structure();
    for (0..fields) |_| {
        switch (try reader.vint()) {
            0 => player = try reader.integer(),
            1 => {
                const stats_fields = try reader.structure();
                for (0..stats_fields) |_| {
                    switch (try reader.vint()) {
                        0 => values[0] = try reader.integer(),
                        1 => values[1] = try reader.integer(),
                        4 => values[4] = try reader.integer(),
                        // Build 75689: minerals lost Army/Economy/Technology,
                        // then vespene lost in the same category order.
                        17...22 => |field| lost[@intCast(field - 17)] = try reader.signedInteger(),
                        29 => values[2] = try reader.integer(),
                        30 => values[3] = try reader.integer(),
                        else => try reader.skip(0),
                    }
                }
            },
            else => try reader.skip(0),
        }
    }
    const id = player orelse return error.MissingPlayerStats;
    if (id == 0 or id >= 16) return error.InvalidPlayerId;
    const used = @as(f32, @floatFromInt(values[2] orelse return error.MissingPlayerStats)) / 4096;
    const workers = values[4] orelse return error.MissingPlayerStats;
    return .{ .player_id = @intCast(id), .values = .{
        .game_loop = loop,
        .minerals = values[0] orelse return error.MissingPlayerStats,
        .vespene = values[1] orelse return error.MissingPlayerStats,
        .food_used = used,
        .food_cap = @min(200, @as(f32, @floatFromInt(values[3] orelse return error.MissingPlayerStats)) / 4096),
        .worker_supply = workers,
        .resource_losses = if (allLossFieldsPresent(lost)) .{
            .army = .{ .minerals = lost[0].?, .vespene = lost[3].? },
            .economy = .{ .minerals = lost[1].?, .vespene = lost[4].? },
            .technology = .{ .minerals = lost[2].?, .vespene = lost[5].? },
        } else null,
    } };
}

fn allLossFieldsPresent(fields: [6]?i32) bool {
    for (fields) |value| if (value == null) return false;
    return true;
}

const TrackedUnit = struct { owner: u32, name: losses.Name };

// The identity includes the recycle counter: a reused index is a different unit.
fn readUnitEvent(reader: *Reader, allocator: std.mem.Allocator, units: *std.AutoHashMapUnmanaged(u64, TrackedUnit), deaths: *std.ArrayList(losses.Death), event: u32, loop: u32) !void {
    var index: ?u32 = null;
    var recycle: ?u32 = null;
    var owner: ?u32 = null;
    var name: ?losses.Name = null;
    const fields = try reader.structure();
    for (0..fields) |_| {
        const field = try reader.vint();
        if (field == 0) {
            index = try reader.integer();
        } else if (field == 1) {
            recycle = try reader.integer();
        } else if (field == 2 and (event == 1 or event == 4 or event == 6)) {
            name = try reader.name();
        } else if ((field == 4 and (event == 1 or event == 6)) or (field == 3 and event == 3)) {
            // Upkeep owner, not the controller (shared control can differ).
            owner = try reader.integer();
        } else try reader.skip(0);
    }
    const key = (@as(u64, index orelse return error.MissingUnitIdentity) << 32) |
        (recycle orelse return error.MissingUnitIdentity);
    switch (event) {
        1, 6 => try units.put(allocator, key, .{
            .owner = owner orelse return error.MissingUnitOwner,
            .name = name orelse return error.MissingUnitType,
        }),
        2 => {
            const unit = units.fetchRemove(key) orelse return error.UnknownTrackerUnit;
            if (unit.value.owner > 0 and unit.value.owner < 16) {
                try deaths.append(allocator, .{ .game_loop = loop, .owner = unit.value.owner, .name = unit.value.name });
            }
        },
        3 => {
            const unit = units.getPtr(key) orelse return error.UnknownTrackerUnit;
            unit.owner = owner orelse return error.MissingUnitOwner;
        },
        4 => {
            const unit = units.getPtr(key) orelse return error.UnknownTrackerUnit;
            unit.name = name orelse return error.MissingUnitType;
        },
        else => unreachable,
    }
}

fn decode(allocator: std.mem.Allocator, bytes: []const u8) !Timeline {
    var reader: Reader = .{ .bytes = bytes };
    var samples: std.ArrayList(Sample) = .empty;
    defer samples.deinit(allocator);
    var deaths: std.ArrayList(losses.Death) = .empty;
    defer deaths.deinit(allocator);
    var units: std.AutoHashMapUnmanaged(u64, TrackedUnit) = .empty;
    defer units.deinit(allocator);
    var loop: u32 = 0;
    while (reader.pos < bytes.len) {
        try reader.expect(3); // SVarUint32 tagged choice
        const choice = try reader.vint();
        if (choice < 0 or choice > 3) return error.InvalidTrackerEncoding;
        loop = std.math.add(u32, loop, try reader.integer()) catch return error.InvalidTrackerEncoding;
        const event = try reader.integer();
        if (event == 0) {
            const sample = try readSample(&reader, loop);
            try samples.append(allocator, sample);
        } else if (event == 1 or event == 2 or event == 3 or event == 4 or event == 6) {
            try readUnitEvent(&reader, allocator, &units, &deaths, event, loop);
        } else try reader.skip(0);
    }
    if (samples.items.len == 0) return error.MissingPlayerStats;
    const owned_samples = try samples.toOwnedSlice(allocator);
    errdefer allocator.free(owned_samples);
    return .{ .samples = owned_samples, .deaths = try deaths.toOwnedSlice(allocator) };
}

// Small versioned-encoding fixtures, independent of an SC2 installation/replay.
const TestTracker = struct {
    bytes: std.ArrayList(u8) = .empty,
    allocator: std.mem.Allocator,
    fn raw(self: *TestTracker, bytes: []const u8) !void {
        try self.bytes.appendSlice(self.allocator, bytes);
    }
    fn vint(self: *TestTracker, value: i64) !void {
        var rest: u64 = (@as(u64, @intCast(if (value < 0) -value else value)) << 1) | @intFromBool(value < 0);
        while (rest >= 128) {
            try self.bytes.append(self.allocator, @as(u8, @intCast(rest & 127)) | 128);
            rest >>= 7;
        }
        try self.bytes.append(self.allocator, @intCast(rest));
    }
    fn integer(self: *TestTracker, value: u32) !void {
        try self.raw(&.{9});
        try self.vint(value);
    }
    fn event(self: *TestTracker, id: u32, delta: u32, index: u32, recycle: u32, name: ?[]const u8, owner: ?u32) !void {
        try self.raw(&.{ 3, 0 }); // loop delta choice
        try self.integer(delta);
        try self.integer(id);
        try self.raw(&.{5});
        try self.vint(2 + @as(u32, @intFromBool(name != null)) + @as(u32, @intFromBool(owner != null)));
        try self.vint(0);
        try self.integer(index);
        try self.vint(1);
        try self.integer(recycle);
        if (name) |value| {
            try self.vint(2);
            try self.raw(&.{2});
            try self.vint(@intCast(value.len));
            try self.raw(value);
        }
        if (owner) |value| {
            try self.vint(if (id == 3) 3 else 4);
            try self.integer(value);
        }
    }
    fn stats(self: *TestTracker, delta: u32, player: u32, lost: []const i32) !void {
        try self.raw(&.{ 3, 0 });
        try self.integer(delta);
        try self.integer(0);
        try self.raw(&.{ 5, 4, 0 }); // Two event fields; player ID first.
        try self.integer(player);
        try self.raw(&.{ 2, 5 }); // Stats field, nested structure.
        try self.vint(@intCast(5 + lost.len));
        for ([_]u32{ 0, 1, 4, 29, 30 }) |field| {
            try self.vint(field);
            try self.integer(0);
        }
        for (lost, 17..) |value, field| {
            try self.vint(@intCast(field));
            try self.raw(&.{9});
            try self.vint(value);
        }
    }
    fn fixture(self: *TestTracker) !void {
        try self.stats(0, 3, &.{ 100, 200, 300, 400, 500, 600 });
        try self.event(1, 0, 10, 1, "Marine", 3);
        try self.event(4, 1, 10, 1, "MarineBurrowed", null);
        try self.event(3, 1, 10, 1, null, 7);
        try self.event(2, 1, 10, 1, null, null);
        // Construction-start and born events, with a reused index, are distinct.
        try self.event(6, 0, 10, 2, "Barracks", 3);
        try self.event(1, 0, 10, 3, "SCV", 3);
        try self.event(2, 1, 10, 2, null, null);
        try self.event(2, 0, 10, 3, null, null);
        // Neutral deaths are not player losses.
        try self.event(1, 0, 20, 1, "MineralField", 0);
        try self.event(2, 0, 20, 1, null, null);
        // Unhandled well-formed event is still skipped.
        try self.raw(&.{ 3, 0, 9, 0, 9, 14, 5, 0 });
    }
};

test "recorded resource losses decode categories and select preceding sample per player" {
    var fixture: TestTracker = .{ .allocator = std.testing.allocator };
    defer fixture.bytes.deinit(fixture.allocator);
    try fixture.stats(1, 3, &.{ 100, 200, 300, 400, 500, 600 });
    try fixture.stats(9, 7, &.{ 1, 2, 3, 4, 5, 6 });
    try fixture.stats(150, 3, &.{ 110, 220, 330, 440, 550, 660 });
    const timeline = try decode(std.testing.allocator, fixture.bytes.items);
    defer timeline.deinit(std.testing.allocator);
    var players: data.Players = .{};
    players.add(7, "Bob");
    players.add(3, "Alice");
    try std.testing.expect(timeline.at(0, &players).forPlayer(3) == null);
    const before = timeline.at(159, &players).forPlayer(3).?.resource_losses.?;
    try std.testing.expectEqualDeep(data.ResourceLoss{ .minerals = 100, .vespene = 400 }, before.army);
    try std.testing.expectEqualDeep(data.ResourceLoss{ .minerals = 200, .vespene = 500 }, before.economy);
    try std.testing.expectEqualDeep(data.ResourceLoss{ .minerals = 300, .vespene = 600 }, before.technology);
    const now = timeline.at(160, &players);
    try std.testing.expectEqual(@as(i32, 110), now.forPlayer(3).?.resource_losses.?.army.minerals);
    try std.testing.expectEqual(@as(i32, 1), now.forPlayer(7).?.resource_losses.?.army.minerals);
}

test "signed game-recorded resource adjustments are preserved" {
    var fixture: TestTracker = .{ .allocator = std.testing.allocator };
    defer fixture.bytes.deinit(fixture.allocator);
    try fixture.stats(0, 3, &.{ -50, 0, -25, 0, -100, 0 });
    const timeline = try decode(std.testing.allocator, fixture.bytes.items);
    defer timeline.deinit(std.testing.allocator);
    const recorded = timeline.samples[0].values.resource_losses.?;
    try std.testing.expectEqual(@as(i32, -50), recorded.army.minerals);
    try std.testing.expectEqual(@as(i32, -100), recorded.economy.vespene);
    try std.testing.expectEqual(@as(i32, -25), recorded.technology.minerals);
    fixture.bytes.clearRetainingCapacity();
    try fixture.raw(&.{9});
    try fixture.vint(@as(i64, std.math.maxInt(i32)) + 1);
    var reader: Reader = .{ .bytes = fixture.bytes.items };
    try std.testing.expectError(error.InvalidTrackerEncoding, reader.signedInteger());
}

test "missing resource loss fields do not become fabricated zero values" {
    var fixture: TestTracker = .{ .allocator = std.testing.allocator };
    defer fixture.bytes.deinit(fixture.allocator);
    const zeros = [_]i32{ 0, 0, 0, 0, 0, 0 };
    // No fields, incomplete fields, and a complete recorded zero sample.
    for ([_]usize{ 0, 5, 6 }) |count| {
        fixture.bytes.clearRetainingCapacity();
        try fixture.stats(0, 3, zeros[0..count]);
        const timeline = try decode(std.testing.allocator, fixture.bytes.items);
        defer timeline.deinit(std.testing.allocator);
        try std.testing.expectEqual(count == 6, timeline.samples[0].values.resource_losses != null);
    }
}

test "tracker lifecycle resolves type and owner at death, recycled identities and neutral units" {
    var fixture: TestTracker = .{ .allocator = std.testing.allocator };
    defer fixture.bytes.deinit(fixture.allocator);
    try fixture.fixture();
    const timeline = try decode(std.testing.allocator, fixture.bytes.items);
    defer timeline.deinit(std.testing.allocator);
    @memset(fixture.bytes.items, 0); // No borrowed names survive decoding.
    try std.testing.expectEqual(@as(usize, 3), timeline.deaths.len);
    try std.testing.expectEqual(@as(u32, 3), timeline.deaths[0].game_loop);
    try std.testing.expectEqual(@as(u32, 7), timeline.deaths[0].owner);
    try std.testing.expectEqualStrings("MarineBurrowed", std.mem.sliceTo(&timeline.deaths[0].name, 0));
    try std.testing.expectEqualStrings("Barracks", std.mem.sliceTo(&timeline.deaths[1].name, 0));
    try std.testing.expectEqualStrings("SCV", std.mem.sliceTo(&timeline.deaths[2].name, 0));
    try std.testing.expectEqual(@as(u32, 3), timeline.deaths[2].owner);
}

test "tracker decode cleans every allocation failure" {
    var fixture: TestTracker = .{ .allocator = std.testing.allocator };
    defer fixture.bytes.deinit(fixture.allocator);
    try fixture.fixture();
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(allocator: std.mem.Allocator, bytes: []const u8) !void {
            const timeline = try decode(allocator, bytes);
            defer timeline.deinit(allocator);
        }
    }.run, .{fixture.bytes.items});
}

test "unresolved or malformed lifecycle records fail rather than fabricate zero losses" {
    var fixture: TestTracker = .{ .allocator = std.testing.allocator };
    defer fixture.bytes.deinit(fixture.allocator);
    try fixture.event(2, 0, 10, 1, null, null);
    try std.testing.expectError(error.UnknownTrackerUnit, decode(std.testing.allocator, fixture.bytes.items));
    fixture.bytes.clearRetainingCapacity();
    try fixture.event(1, 0, 10, 1, null, 3);
    try std.testing.expectError(error.MissingUnitType, decode(std.testing.allocator, fixture.bytes.items));
    // Missing tag recycle field.
    try std.testing.expectError(error.MissingUnitIdentity, decode(std.testing.allocator, &.{ 3, 0, 9, 0, 9, 4, 5, 2, 0, 9, 20 }));
}

test "tagged decoder rejects excessive lengths, nesting, varints and loop overflow" {
    var huge: Reader = .{ .bytes = &.{ 2, 126 } };
    try std.testing.expectError(error.InvalidTrackerEncoding, huge.skip(0));
    var number: Reader = .{ .bytes = &.{ 255, 255, 255, 255, 255, 255, 255, 255, 255, 127 } };
    try std.testing.expectError(error.InvalidTrackerEncoding, number.vint());
    var nested: [70]u8 = undefined;
    for (0..35) |i| {
        nested[i * 2] = 4;
        nested[i * 2 + 1] = 1;
    }
    var deep: Reader = .{ .bytes = &nested };
    try std.testing.expectError(error.InvalidTrackerEncoding, deep.skip(0));
    const overflow = [_]u8{ 3, 0, 9, 0xfe, 0xff, 0xff, 0xff, 0x1f, 9, 0xc6, 1, 5, 0, 3, 0, 9, 2 };
    try std.testing.expectError(error.InvalidTrackerEncoding, decode(std.testing.allocator, &overflow));
    // No sample events is not a successful empty timeline.
    try std.testing.expectError(error.MissingPlayerStats, decode(std.testing.allocator, &.{}));
}

pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) !Timeline {
    if (!std.mem.eql(u8, try range(bytes, 0, 4), "MPQ\x1b")) return error.UnsupportedArchive;
    const base = try le32(bytes, 8);
    const header_len = try le32(bytes, 12);
    if (base < 16 or header_len > base - 16) return error.InvalidArchive;
    try checkBuild(try range(bytes, 16, header_len));
    const tracker = try extract(allocator, bytes, base);
    defer allocator.free(tracker);
    return decode(allocator, tracker);
}
