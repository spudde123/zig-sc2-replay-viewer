//! Narrow build-75689 replay reader: MPQ v3 single-unit tracker file and
//! Blizzard's versioned tracker encoding. Not a general-purpose replay parser.
//! Format/algorithm references: mpyq (BSD-2-Clause), s2protocol (MIT).
//! Notices are in licenses/mpyq.txt and licenses/s2protocol.txt.
const std = @import("std");
const data = @import("replay_data.zig");
const max_file = 64 * 1024 * 1024;
const max_tracker = 16 * 1024 * 1024;

pub const Sample = struct { player_id: u8, values: data.PlayerEconomy };
pub const Timeline = struct {
    samples: []Sample,
    player_mask: u16,
    pub fn deinit(self: Timeline, allocator: std.mem.Allocator) void {
        allocator.free(self.samples);
    }
    pub fn at(self: Timeline, loop: u32) data.PlayerStats {
        var result: data.PlayerStats = .{ .available = true };
        var lo: usize = 0;
        var hi = self.samples.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.samples[mid].values.game_loop <= loop) lo = mid + 1 else hi = mid;
        }
        var found: u16 = 0;
        while (lo > 0 and found != self.player_mask) {
            lo -= 1;
            const sample = self.samples[lo];
            const bit = @as(u16, 1) << @as(u4, @intCast(sample.player_id));
            if (found & bit == 0) {
                result.items[sample.player_id] = sample.values;
                found |= bit;
            }
        }
        return result;
    }
};

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
    var values: [4]?u32 = @splat(null);
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
    return .{ .player_id = @intCast(id), .values = .{ .game_loop = loop, .minerals = values[0] orelse return error.MissingPlayerStats, .vespene = values[1] orelse return error.MissingPlayerStats, .food_used = @as(f32, @floatFromInt(values[2] orelse return error.MissingPlayerStats)) / 4096, .food_cap = @min(200, @as(f32, @floatFromInt(values[3] orelse return error.MissingPlayerStats)) / 4096) } };
}

fn decode(allocator: std.mem.Allocator, bytes: []const u8) !Timeline {
    var reader: Reader = .{ .bytes = bytes };
    var samples: std.ArrayList(Sample) = .empty;
    defer samples.deinit(allocator);
    var loop: u32 = 0;
    var mask: u16 = 0;
    while (reader.pos < bytes.len) {
        try reader.expect(3); // SVarUint32 tagged choice
        const choice = try reader.vint();
        if (choice < 0 or choice > 3) return error.InvalidTrackerEncoding;
        loop = std.math.add(u32, loop, try reader.integer()) catch return error.InvalidTrackerEncoding;
        const event = try reader.integer();
        if (event == 0) {
            const sample = try readSample(&reader, loop);
            try samples.append(allocator, sample);
            mask |= @as(u16, 1) << @as(u4, @intCast(sample.player_id));
        } else try reader.skip(0);
    }
    if (samples.items.len == 0) return error.MissingPlayerStats;
    return .{ .samples = try samples.toOwnedSlice(allocator), .player_mask = mask };
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
