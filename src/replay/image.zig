const std = @import("std");
const protocol = @import("zig-sc2").sc2p;
const observation_data = @import("observation_data.zig");

pub const Image = struct {
    width: i32,
    height: i32,
    pixels: []u8,

    pub fn deinit(self: Image, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
    }

    /// SC2 RGB images are tightly packed, top-left origin; never retain borrowed bytes.
    pub fn fromProto(allocator: std.mem.Allocator, image: protocol.ImageData) !Image {
        const size = image.size orelse return error.MissingImageSize;
        const width = size.x orelse return error.MissingImageSize;
        const height = size.y orelse return error.MissingImageSize;
        if (width <= 0 or height <= 0 or width > 4096 or height > 4096) return error.InvalidImageSize;
        const bpp = image.bits_per_pixel orelse return error.MissingPixelFormat;
        if (bpp != 24 and bpp != 32) return error.UnsupportedPixelFormat;
        const count = try std.math.mul(usize, @intCast(width), @intCast(height));
        const stride: usize = @intCast(@divExact(bpp, 8));
        const bytes = image.image orelse return error.MissingImageData;
        if (bytes.len != try std.math.mul(usize, count, stride)) return error.InvalidImageLength;
        const pixels = try allocator.alloc(u8, try std.math.mul(usize, count, 4));
        for (0..count) |i| {
            @memcpy(pixels[i * 4 ..][0..3], bytes[i * stride ..][0..3]);
            pixels[i * 4 + 3] = 255;
        }
        return .{ .width = width, .height = height, .pixels = pixels };
    }

    fn darkenWhitePadding(self: Image) void {
        const width: usize = @intCast(self.width);
        const height: usize = @intCast(self.height);
        var left: usize = 0;
        while (left < width and self.whiteLine(left, width, height)) : (left += 1) {}
        // An entirely white image has no identifiable map content; leave it alone.
        if (left == width) return;
        var right = width;
        while (right > left and self.whiteLine(right - 1, width, height)) : (right -= 1) {}
        var top: usize = 0;
        while (top < height and self.whiteLine(top * width, 1, width)) : (top += 1) {}
        var bottom = height;
        while (bottom > top and self.whiteLine((bottom - 1) * width, 1, width)) : (bottom -= 1) {}
        // Detect every band before recoloring, so corners cannot affect detection.
        for (0..height) |y| {
            for (0..width) |x| {
                if (x < left or x >= right or y < top or y >= bottom)
                    @memcpy(self.pixels[(y * width + x) * 4 ..][0..4], &[_]u8{ 12, 14, 18, 255 });
            }
        }
    }

    fn whiteLine(self: Image, start: usize, stride: usize, count: usize) bool {
        for (0..count) |i| {
            const pixel = (start + i * stride) * 4;
            if (!std.mem.eql(u8, self.pixels[pixel..][0..3], &.{ 255, 255, 255 })) return false;
        }
        return true;
    }

    pub fn writePpm(self: Image, allocator: std.mem.Allocator, io: std.Io, path: []const u8) !void {
        const header = try std.fmt.allocPrint(allocator, "P6\n{d} {d}\n255\n", .{ self.width, self.height });
        defer allocator.free(header);
        const count = self.pixels.len / 4;
        const data = try allocator.alloc(u8, header.len + count * 3);
        defer allocator.free(data);
        @memcpy(data[0..header.len], header);
        for (0..count) |i| @memcpy(data[header.len + i * 3 ..][0..3], self.pixels[i * 4 ..][0..3]);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data });
    }
};

pub const Frame = struct {
    map: Image,
    minimap: ?Image,
    game_loop: u32,
    ended: bool,
    scene: @import("replay_data.zig").Scene = .{},

    pub fn fromObservation(allocator: std.mem.Allocator, response: protocol.ResponseObservation, status: protocol.Status) !Frame {
        return fromObservationWithContext(allocator, response, status, .{});
    }

    pub fn fromObservationWithContext(allocator: std.mem.Allocator, response: protocol.ResponseObservation, status: protocol.Status, context: observation_data.Context) !Frame {
        const obs = response.observation orelse return error.MissingObservation;
        const render = obs.render orelse return error.MissingRenderedImage;
        const map = try Image.fromProto(allocator, render.map orelse return error.MissingRenderedImage);
        errdefer map.deinit(allocator);
        const minimap = if (render.minimap) |m| try Image.fromProto(allocator, m) else null;
        errdefer if (minimap) |m| m.deinit(allocator);
        if (minimap) |m| m.darkenWhitePadding();
        const scene = try observation_data.capture(allocator, obs.raw, context);
        return .{
            .map = map,
            .minimap = minimap,
            .scene = scene,
            .game_loop = obs.game_loop orelse 0,
            .ended = status == .ended or (if (response.player_result) |r| r.len > 0 else false),
        };
    }

    pub fn deinit(self: Frame, allocator: std.mem.Allocator) void {
        self.map.deinit(allocator);
        if (self.minimap) |m| m.deinit(allocator);
        self.scene.deinit(allocator);
    }
};

test "snapshot construction cleans up every partial allocation on failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(allocator: std.mem.Allocator) !void {
            var pixels = [_]u8{ 10, 20, 30 };
            const image: protocol.ImageData = .{ .size = .{ .x = 1, .y = 1 }, .bits_per_pixel = 24, .image = &pixels };
            var orders = [_]protocol.UnitOrder{.{ .target = .{ .tag = 2 } }};
            var units = [_]protocol.Unit{.{ .tag = 1, .orders = &orders }};
            const frame = try Frame.fromObservation(allocator, .{ .observation = .{
                .render = .{ .map = image, .minimap = image },
                .raw = .{ .units = &units },
            } }, .in_replay);
            defer frame.deinit(allocator);
        }
    }.run, .{});
}

test "RGB conversion owns its bytes and preserves orientation" {
    var source = [_]u8{ 255, 0, 0, 0, 255, 0 };
    const image = try Image.fromProto(std.testing.allocator, .{ .size = .{ .x = 1, .y = 2 }, .bits_per_pixel = 24, .image = &source });
    defer image.deinit(std.testing.allocator);
    source[0] = 0;
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255, 0, 255, 0, 255 }, image.pixels);
}

test "RGBA input and ended observations" {
    var source = [_]u8{ 1, 2, 3, 0 };
    const frame = try Frame.fromObservation(std.testing.allocator, .{ .observation = .{
        .game_loop = 200,
        .render = .{ .map = .{ .size = .{ .x = 1, .y = 1 }, .bits_per_pixel = 32, .image = &source } },
    } }, .ended);
    defer frame.deinit(std.testing.allocator);
    try std.testing.expect(frame.ended);
    try std.testing.expectEqual(@as(u32, 200), frame.game_loop);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 255 }, frame.map.pixels);
    try std.testing.expectError(error.MissingRenderedImage, Frame.fromObservation(std.testing.allocator, .{ .observation = .{} }, .in_replay));
}

test "only minimap edge bands darken; main image and white markers stay intact" {
    var source: [7 * 5 * 4]u8 = @splat(255);
    for (1..4) |y| {
        for (2..6) |x| @memcpy(source[(y * 7 + x) * 4 ..][0..4], &[_]u8{ 0, 0, 0, 255 });
    }
    @memcpy(source[(2 * 7 + 3) * 4 ..][0..4], &[_]u8{ 255, 255, 255, 255 });
    const proto: protocol.ImageData = .{ .size = .{ .x = 7, .y = 5 }, .bits_per_pixel = 32, .image = &source };
    const frame = try Frame.fromObservation(std.testing.allocator, .{ .observation = .{
        .render = .{ .map = proto, .minimap = proto },
    } }, .in_replay);
    defer frame.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, &source, frame.map.pixels);
    try std.testing.expectEqual(@as(i32, 7), frame.minimap.?.width);
    try std.testing.expectEqual(@as(i32, 5), frame.minimap.?.height);
    for (0..5) |y| {
        for (0..7) |x| {
            const offset = (y * 7 + x) * 4;
            const expected: []const u8 = if (x < 2 or x >= 6 or y < 1 or y >= 4)
                &.{ 12, 14, 18, 255 }
            else
                source[offset..][0..4];
            try std.testing.expectEqualSlices(u8, expected, frame.minimap.?.pixels[offset..][0..4]);
        }
    }
}

test "all-white minimaps and isolated white edge pixels are left unchanged" {
    var pixels: [3 * 3 * 4]u8 = @splat(255);
    const image: Image = .{ .width = 3, .height = 3, .pixels = &pixels };
    const all_white = pixels;
    image.darkenWhitePadding();
    try std.testing.expectEqualSlices(u8, &all_white, &pixels);
    @memset(&pixels, 0);
    @memcpy(pixels[0..4], &[_]u8{ 255, 255, 255, 255 });
    const isolated_white = pixels;
    image.darkenWhitePadding();
    try std.testing.expectEqualSlices(u8, &isolated_white, &pixels);
}

test "invalid images are rejected" {
    var source = [_]u8{0};
    try std.testing.expectError(error.InvalidImageSize, Image.fromProto(std.testing.allocator, .{ .size = .{ .x = -1, .y = 1 }, .bits_per_pixel = 24, .image = &source }));
    try std.testing.expectError(error.InvalidImageLength, Image.fromProto(std.testing.allocator, .{ .size = .{ .x = 1, .y = 1 }, .bits_per_pixel = 24, .image = &source }));
    try std.testing.expectError(error.UnsupportedPixelFormat, Image.fromProto(std.testing.allocator, .{ .size = .{ .x = 1, .y = 1 }, .bits_per_pixel = 8, .image = &source }));
}
