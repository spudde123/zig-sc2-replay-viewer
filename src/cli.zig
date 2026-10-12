const std = @import("std");
const sc2 = @import("zig-sc2");

pub const Options = struct {
    session: sc2.ReplaySession.Config = .{ .installation = "", .replay = "", .player_id = 0 },
    probe: bool = false,
    capture: ?[]const u8 = null,
    probe_loops: u32 = 64,
    camera_distance: f32 = 40,
    quit_after: ?f64 = null,
};

pub const usage =
    \\Usage: zig_sc2_replay_watcher --replay PATH --sc2 INSTALL_ROOT [options]
    \\  --player ID           Player perspective (default: 0, all-player observer)
    \\  --disable-fog         Set SC2's startup fog flag (not an RGB perspective switch)
    \\  --egl PATH            EGL library (default: /usr/lib64/libEGL.so.1)
    \\  --osmesa PATH         Software rendering instead of EGL
    \\  --port PORT           API port (default: 5000)
    \\  --width N --height N  Render resolution (default: 640x480)
    \\  --camera-distance N   Initial camera distance (10-100, default: 40)
    \\  --verbose-sc2         Show SC2's own stdout/stderr
    \\  --probe               Test replay rendering without opening a window
    \\  --probe-loops N       Loops to advance for probe (default: 64)
    \\  --capture PATH        Save final probe/displayed frame as PPM
    \\  --quit-after SECONDS  Automatically close window (smoke testing)
    \\Keys: Space pause; Up/Down or [ / ] speed; Right step paused; Escape quit.
    \\Click minimap to move the camera. WASD pans; mouse wheel or +/- zooms.
    \\
;

pub fn parse(args: []const []const u8) !Options {
    var result: Options = .{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const key = args[i];
        if (std.mem.eql(u8, key, "--help") or std.mem.eql(u8, key, "-h")) return error.HelpRequested;
        if (std.mem.eql(u8, key, "--disable-fog")) {
            result.session.disable_fog = true;
            continue;
        }
        if (std.mem.eql(u8, key, "--verbose-sc2")) {
            result.session.verbose = true;
            continue;
        }
        if (std.mem.eql(u8, key, "--probe")) {
            result.probe = true;
            continue;
        }
        i += 1;
        if (i == args.len) return error.MissingOptionValue;
        const value = args[i];
        if (std.mem.eql(u8, key, "--replay")) {
            result.session.replay = value;
        } else if (std.mem.eql(u8, key, "--sc2")) {
            result.session.installation = value;
        } else if (std.mem.eql(u8, key, "--egl")) {
            result.session.egl_path = value;
        } else if (std.mem.eql(u8, key, "--osmesa")) {
            result.session.osmesa_path = value;
        } else if (std.mem.eql(u8, key, "--player")) {
            result.session.player_id = try std.fmt.parseInt(u32, value, 10);
        } else if (std.mem.eql(u8, key, "--port")) {
            result.session.port = try std.fmt.parseInt(u16, value, 10);
        } else if (std.mem.eql(u8, key, "--width")) {
            result.session.width = try std.fmt.parseInt(i32, value, 10);
        } else if (std.mem.eql(u8, key, "--height")) {
            result.session.height = try std.fmt.parseInt(i32, value, 10);
        } else if (std.mem.eql(u8, key, "--camera-distance")) {
            result.camera_distance = try std.fmt.parseFloat(f32, value);
            if (!std.math.isFinite(result.camera_distance) or result.camera_distance < 10 or result.camera_distance > 100) return error.InvalidCameraDistance;
        } else if (std.mem.eql(u8, key, "--probe-loops")) {
            result.probe_loops = try std.fmt.parseInt(u32, value, 10);
        } else if (std.mem.eql(u8, key, "--capture")) {
            result.capture = value;
        } else if (std.mem.eql(u8, key, "--quit-after")) {
            result.quit_after = try std.fmt.parseFloat(f64, value);
            if (!std.math.isFinite(result.quit_after.?) or result.quit_after.? <= 0) return error.InvalidDuration;
        } else return error.UnknownOption;
    }
    if (result.session.replay.len == 0 or result.session.installation.len == 0) return error.MissingRequiredOptions;
    if (result.session.width < 64 or result.session.width > 1920 or result.session.height < 64 or result.session.height > 1080) return error.InvalidResolution;
    if (result.session.port == 0 or (result.session.player_id != null and result.session.player_id.? > std.math.maxInt(i32))) return error.InvalidOption;
    return result;
}

test "CLI required options and malformed values" {
    try std.testing.expectError(error.MissingRequiredOptions, parse(&.{"watcher"}));
    try std.testing.expectError(error.MissingOptionValue, parse(&.{ "watcher", "--replay" }));
    try std.testing.expectError(error.InvalidResolution, parse(&.{ "watcher", "--replay", "r", "--sc2", "s", "--width", "-1" }));
    try std.testing.expectError(error.InvalidDuration, parse(&.{ "watcher", "--replay", "r", "--sc2", "s", "--quit-after", "nan" }));
    const o = try parse(&.{ "watcher", "--replay", "r", "--sc2", "s", "--probe", "--disable-fog" });
    try std.testing.expect(o.probe and o.session.disable_fog);
}

test "CLI camera distance validates finite bounded values" {
    const options = try parse(&.{ "watcher", "--replay", "r", "--sc2", "s", "--camera-distance", "60" });
    try std.testing.expectEqual(@as(f32, 60), options.camera_distance);
    for ([_][]const u8{ "nan", "inf", "0", "101" }) |value| {
        try std.testing.expectError(error.InvalidCameraDistance, parse(&.{ "watcher", "--replay", "r", "--sc2", "s", "--camera-distance", value }));
    }
}

test "CLI defaults to observer zero and validates explicit player IDs" {
    const defaults = try parse(&.{ "watcher", "--replay", "r", "--sc2", "s" });
    try std.testing.expectEqual(@as(?u32, 0), defaults.session.player_id);
    const participant = try parse(&.{ "watcher", "--replay", "r", "--sc2", "s", "--player", "2" });
    try std.testing.expectEqual(@as(?u32, 2), participant.session.player_id);
    const observer = try parse(&.{ "watcher", "--replay", "r", "--sc2", "s", "--player", "0" });
    try std.testing.expectEqual(@as(?u32, 0), observer.session.player_id);
    try std.testing.expectError(error.InvalidOption, parse(&.{ "watcher", "--replay", "r", "--sc2", "s", "--player", "4294967295" }));
    try std.testing.expectError(error.Overflow, parse(&.{ "watcher", "--replay", "r", "--sc2", "s", "--player", "-1" }));
}
