//! Shared colors and token ranges for formatted resource-value rows only.
const std = @import("std");
pub const mineral_blue = [3]u8{ 90, 185, 255 };
pub const vespene_green = [3]u8{ 125, 220, 100 };
pub const Span = struct { begin: usize, end: usize, color: [3]u8 };

/// Works on the displayed (possibly clipped) string. Never scans player names:
/// callers explicitly mark rows which contain formatted resource values.
pub fn spans(value: []const u8) [2]?Span {
    var result: [2]?Span = @splat(null);
    for ([_][]const u8{ "M:", "V:" }, [_][3]u8{ mineral_blue, vespene_green }, 0..) |marker, color, i| {
        const begin = std.mem.indexOf(u8, value, marker) orelse continue;
        if (begin > 0 and value[begin - 1] != ' ') continue;
        const length = std.mem.indexOfScalar(u8, value[begin..], ' ') orelse (value.len - begin);
        result[i] = .{ .begin = begin, .end = begin + length, .color = color };
    }
    return result;
}

test "resource spans include labels and signed values but exclude neutral text" {
    const value = "Army: M:950 V:-350";
    const ranges = spans(value);
    try std.testing.expectEqualStrings("M:950", value[ranges[0].?.begin..ranges[0].?.end]);
    try std.testing.expectEqualStrings("V:-350", value[ranges[1].?.begin..ranges[1].?.end]);
    try std.testing.expectEqual(mineral_blue, ranges[0].?.color);
    try std.testing.expectEqual(vespene_green, ranges[1].?.color);
    const clipped_text = "Tech: M:12 V:";
    const clipped = spans(clipped_text);
    try std.testing.expectEqualStrings("V:", clipped_text[clipped[1].?.begin..clipped[1].?.end]);
    try std.testing.expect(spans("M:12")[1] == null);
    try std.testing.expect(spans("Army: pending")[0] == null);
}
