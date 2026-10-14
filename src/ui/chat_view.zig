//! Display-only chat formatting. Protocol data and worker synchronization stay
//! outside this module; the bounded raw history can later feed a Unicode UI.
const std = @import("std");
const data = @import("../replay/replay_data.zig");
const formatGameTime = @import("../replay/playback.zig").formatGameTime;

pub const max_columns = 80;
pub const max_rows = 12;
const max_message_rows = 3;
pub const Line = struct {
    bytes: [max_columns:0]u8 = @splat(0),
    // Endpoints of the timestamp and sender spans within this wrapped row.
    time_end: usize = 0,
    sender_end: usize = 0,
    message_start: bool = false,
};
pub const Layout = struct {
    lines: [max_rows]Line = @splat(.{}),
    count: usize = 0,

    fn append(self: *Layout, value: []const u8, limit: usize, time_end: usize, sender_end: usize, message_start: bool) void {
        if (limit == 0) return;
        if (self.count == limit) {
            std.mem.copyForwards(Line, self.lines[0 .. limit - 1], self.lines[1..limit]);
            self.count -= 1;
        }
        var line: Line = .{ .time_end = @min(time_end, value.len), .sender_end = @min(sender_end, value.len), .message_start = message_start };
        @memcpy(line.bytes[0..value.len], value);
        self.lines[self.count] = line;
        self.count += 1;
    }
};

/// Bitmap-font-safe text: replace controls with spaces and unsupported Unicode
/// codepoints with '?'. Do not alter the stored source text or interpret markup.
fn ascii(destination: []u8, source: []const u8) []const u8 {
    var input: usize = 0;
    var output: usize = 0;
    while (input < source.len and output < destination.len) {
        const byte = source[input];
        if (byte < 128) {
            destination[output] = if (byte >= 32 and byte <= 126) byte else ' ';
            input += 1;
        } else {
            destination[output] = '?';
            const size: usize = std.unicode.utf8ByteSequenceLength(byte) catch 1;
            if (input + size <= source.len) {
                if (std.unicode.utf8Decode(source[input .. input + size])) |_| {
                    input += size;
                } else |_| {
                    input += 1;
                }
            } else input += 1;
        }
        output += 1;
    }
    return destination[0..output];
}

pub fn build(history: *const data.ChatQueue, players: *const data.Players, column_limit: usize, row_limit: usize) Layout {
    var layout: Layout = .{};
    const columns = std.math.clamp(column_limit, 1, max_columns);
    const rows = @min(row_limit, max_rows);
    if (rows == 0) return layout;
    for (0..history.count) |i| {
        const message = history.at(i);
        var fallback: [48]u8 = undefined;
        const sender = players.name(message.player_id) orelse
            (if (message.player_id == 0) "Unknown" else std.fmt.bufPrint(&fallback, "Player {d}", .{message.player_id}) catch unreachable);
        var name_buffer: [48]u8 = undefined;
        const name = ascii(&name_buffer, sender);
        var text_buffer: [data.ChatMessage.max_bytes]u8 = undefined;
        const body = if (message.len == 0) "(empty message)" else ascii(&text_buffer, message.text());
        var time_buffer: [16]u8 = undefined;
        const time = formatGameTime(&time_buffer, message.game_loop) catch unreachable;
        var formatted_buffer: [640]u8 = undefined;
        const formatted = std.fmt.bufPrint(&formatted_buffer, "{s} {s}: {s}{s}", .{ time, name, body, if (message.truncated) "..." else "" }) catch unreachable;
        var start: usize = 0;
        var message_rows: usize = 0;
        while (start < formatted.len) {
            while (start < formatted.len and formatted[start] == ' ') start += 1;
            if (start == formatted.len) break;
            var end = @min(start + columns, formatted.len);
            if (end < formatted.len and formatted[end] != ' ') {
                if (std.mem.lastIndexOfScalar(u8, formatted[start..end], ' ')) |space| {
                    if (space > 0) end = start + space;
                }
            }
            layout.append(std.mem.trimEnd(u8, formatted[start..end], " "), rows, time.len -| start, (time.len + 1 + name.len + 2) -| start, message_rows == 0);
            start = end;
            message_rows += 1;
            if (message_rows == @min(max_message_rows, rows) and start < formatted.len) {
                const last = &layout.lines[layout.count - 1];
                const len = std.mem.sliceTo(&last.bytes, 0).len;
                @memset(last.bytes[len - @min(len, 3) .. len], '.');
                break;
            }
        }
    }
    return layout;
}

test "chat labels include game time, names, unknown senders and empty messages" {
    var history: data.ChatQueue = .{};
    var players: data.Players = .{};
    players.add(1, "GPT");
    history.push(data.ChatMessage.init(1, 224, "glhf"));
    history.push(data.ChatMessage.init(2, 448, "hi"));
    history.push(data.ChatMessage.init(0, 0, ""));
    const layout = build(&history, &players, 80, 12);
    try std.testing.expectEqual(@as(usize, 3), layout.count);
    try std.testing.expectEqualStrings("00:10 GPT: glhf", std.mem.sliceTo(&layout.lines[0].bytes, 0));
    try std.testing.expect(layout.lines[0].message_start and layout.lines[1].message_start);
    const first = &layout.lines[0];
    try std.testing.expectEqualStrings("00:10", first.bytes[0..first.time_end]);
    try std.testing.expectEqualStrings(" GPT: ", first.bytes[first.time_end..first.sender_end]);
    try std.testing.expectEqualStrings("glhf", std.mem.sliceTo(&first.bytes, 0)[first.sender_end..]);
    try std.testing.expectEqualStrings("00:20 Player 2: hi", std.mem.sliceTo(&layout.lines[1].bytes, 0));
    try std.testing.expectEqualStrings("00:00 Unknown: (empty message)", std.mem.sliceTo(&layout.lines[2].bytes, 0));
}

test "chat wraps safely, replaces control/Unicode text and bounds long messages" {
    var history: data.ChatQueue = .{};
    const players: data.Players = .{};
    history.push(data.ChatMessage.init(1, 0, "hi\n\x00\x1b ä!"));
    const safe = build(&history, &players, 80, 12);
    try std.testing.expectEqualStrings("00:00 Player 1: hi    ?!", std.mem.sliceTo(&safe.lines[0].bytes, 0));
    const long: [600]u8 = @splat('x');
    history.push(data.ChatMessage.init(1, 0, &long));
    const wrapped = build(&history, &players, 20, 12);
    try std.testing.expect(wrapped.count <= 6);
    for (wrapped.lines[0..wrapped.count]) |line| {
        const len = std.mem.sliceTo(&line.bytes, 0).len;
        try std.testing.expect(len <= 20);
        try std.testing.expect(line.time_end <= line.sender_end and line.sender_end <= len);
    }
    try std.testing.expectEqual(@as(usize, 0), wrapped.lines[wrapped.count - 1].sender_end);
    try std.testing.expect(!wrapped.lines[wrapped.count - 1].message_start);
    try std.testing.expect(std.mem.endsWith(u8, std.mem.sliceTo(&wrapped.lines[wrapped.count - 1].bytes, 0), "..."));
    const tiny = build(&history, &players, 1, 1);
    try std.testing.expectEqual(@as(usize, 1), tiny.count);
    try std.testing.expectEqualStrings(".", std.mem.sliceTo(&tiny.lines[0].bytes, 0));
    try std.testing.expectEqual(@as(usize, 0), build(&history, &players, 0, 0).count);
}

test "many oversized messages keep history and layout bounded" {
    var history: data.ChatQueue = .{};
    const players: data.Players = .{};
    const oversized: [4096]u8 = @splat('x');
    for (0..300) |i| history.push(data.ChatMessage.init(1, @intCast(i), &oversized));
    try std.testing.expectEqual(data.ChatQueue.capacity, history.count);
    try std.testing.expectEqual(@as(u64, 172), history.omitted);
    const layout = build(&history, &players, 38, max_rows);
    try std.testing.expectEqual(max_rows, layout.count);
    for (layout.lines[0..layout.count]) |line| {
        try std.testing.expect(std.mem.sliceTo(&line.bytes, 0).len <= 38);
    }
    try std.testing.expect(std.mem.endsWith(u8, std.mem.sliceTo(&layout.lines[layout.count - 1].bytes, 0), "..."));
}

test "chat layout keeps the newest rows" {
    var history: data.ChatQueue = .{};
    const players: data.Players = .{};
    history.push(data.ChatMessage.init(1, 0, "first"));
    history.push(data.ChatMessage.init(1, 0, "second"));
    history.push(data.ChatMessage.init(1, 0, "third"));
    const layout = build(&history, &players, 80, 2);
    try std.testing.expectEqualStrings("00:00 Player 1: second", std.mem.sliceTo(&layout.lines[0].bytes, 0));
    try std.testing.expectEqualStrings("00:00 Player 1: third", std.mem.sliceTo(&layout.lines[1].bytes, 0));
}
