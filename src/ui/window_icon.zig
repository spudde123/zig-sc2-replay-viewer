const sokol = @import("sokol");

// Raw, tightly packed RGBA8 with straight alpha and a top-left origin.
// Regenerate with: uv run --with pillow python tools/convert_icons.py
pub const desc: sokol.app.IconDesc = blk: {
    var icon: sokol.app.IconDesc = .{};
    icon.images[0] = image(16, @embedFile("../assets/logo_16x16.bin"));
    icon.images[1] = image(32, @embedFile("../assets/logo_32x32.bin"));
    icon.images[2] = image(64, @embedFile("../assets/logo_64x64.bin"));
    break :blk icon;
};

fn image(comptime size: comptime_int, comptime pixels: []const u8) sokol.app.ImageDesc {
    if (pixels.len != size * size * 4) @compileError("Invalid RGBA8 icon size");
    return .{
        .width = size,
        .height = size,
        .pixels = .{ .ptr = pixels.ptr, .size = pixels.len },
    };
}
