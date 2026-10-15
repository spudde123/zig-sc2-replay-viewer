//! Native Linux replay lifecycle without the bot runner's blocking loop.
const std = @import("std");
const sc2 = @import("zig-sc2");
const protocol = sc2.sc2p;
const Client = sc2.ws.WebSocketClient;

pub const ReplaySession = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    child: std.process.Child,
    client: Client,
    player_id: u32,
    duration_loops: u32,
    map_name: []const u8,
    map_width: f32,
    map_height: f32,
    players: [16]Player,
    player_count: usize,

    /// Value-owned display metadata, independent of the response allocator.
    pub const Player = struct {
        id: u32 = 0,
        name: [32:0]u8 = @splat(0),
    };

    pub const Config = struct {
        installation: []const u8,
        replay: []const u8,
        port: u16 = 5000,
        /// null selects the first participant; 0 requests the all-player observer view.
        player_id: ?u32 = null,
        disable_fog: bool = false,
        egl_path: ?[]const u8 = "/usr/lib64/libEGL.so.1",
        osmesa_path: ?[]const u8 = null,
        width: i32 = 640,
        height: i32 = 480,
        minimap_size: i32 = 128,
        verbose: bool = false,
        /// Optional participant-count restriction, checked before starting the replay.
        required_player_count: ?usize = null,
    };

    /// Metadata is owned until close(). All protocol responses use response_allocator,
    /// which the caller may reset after consuming an observation.
    /// All blocking operations are std.Io cancelation points.
    pub fn open(allocator: std.mem.Allocator, io: std.Io, config: Config, response_allocator: std.mem.Allocator) !ReplaySession {
        if (@import("builtin").os.tag != .linux) return error.LinuxOnly;
        if (config.port == 0 or config.width <= 0 or config.height <= 0 or config.minimap_size <= 0) return error.InvalidConfiguration;
        // Refuse to accidentally attach to someone else's SC2 on an occupied port.
        const address = try std.Io.net.IpAddress.parse("127.0.0.1", config.port);
        var reservation = address.listen(io, .{ .reuse_address = true }) catch |err| {
            std.log.err("Cannot reserve API port {d}: {s}", .{ config.port, @errorName(err) });
            return err;
        };
        reservation.deinit(io);
        const latest = try latestBuild(allocator, io, config.installation);
        var child = try launch(allocator, io, config, latest);
        errdefer child.kill(io);
        var client = try connect(io, config.port, response_allocator);
        errdefer client.deinit();

        const info = try client.getReplayInfo(config.replay);
        if (config.required_player_count) |count| {
            validatePlayerCount(info.player_info orelse &.{}, count) catch |err| {
                std.log.err("Replay must have exactly {d} non-observer participants: {s}.", .{ count, @errorName(err) });
                return err;
            };
        }
        const map_name = try allocator.dupe(u8, info.map_name orelse "Replay");
        errdefer allocator.free(map_name);
        var players: [16]Player = @splat(.{});
        var player_count: usize = 0;
        for (info.player_info orelse &.{}) |extra| {
            const player = extra.player_info orelse continue;
            const id = player.player_id orelse continue;
            if (id == 0 or player.player_type == .observer) continue;
            if (player_count == players.len) break;
            players[player_count].id = id;
            if (player.player_name) |name| {
                const len = @min(name.len, players[player_count].name.len);
                @memcpy(players[player_count].name[0..len], name[0..len]);
            }
            player_count += 1;
        }
        const duration = info.game_duration_loops orelse 0;
        const observed = try selectPlayer(info.player_info orelse &.{}, config.player_id);
        std.log.info("Replay: {s}, player {d}, {d} loops", .{ map_name, observed, duration });

        // Replays must match the installed 4.10 Linux client and game data.
        // Reuse this process rather than selecting another build/data version.
        try client.startReplayWithOptions(config.replay, observed, config.disable_fog, false, .{
            .raw = true,
            .score = false,
            .render = .{
                .resolution = .{ .x = config.width, .y = config.height },
                .minimap_resolution = .{ .x = config.minimap_size, .y = config.minimap_size },
            },
        });
        const game = try client.getGameInfo();
        const size = if (game.start_raw) |raw| raw.map_size else null;
        std.log.info("Map dimensions: {d}x{d}", .{ if (size) |s| s.x orelse 256 else 256, if (size) |s| s.y orelse 256 else 256 });
        return .{
            .io = io,
            .allocator = allocator,
            .child = child,
            .client = client,
            .player_id = observed,
            .duration_loops = duration,
            .map_name = map_name,
            .players = players,
            .player_count = player_count,
            .map_width = @floatFromInt(if (size) |s| s.x orelse 256 else 256),
            .map_height = @floatFromInt(if (size) |s| s.y orelse 256 else 256),
        };
    }

    pub fn observe(self: *ReplaySession) !protocol.ResponseObservation {
        return self.client.getObservation(null);
    }

    pub fn advance(self: *ReplaySession, loops: u32) !void {
        if (loops == 0) return error.InvalidStepCount;
        return self.client.step(loops);
    }

    /// Uncancelable bounded-by-child-termination cleanup: no protocol quit request
    /// that could hang forever on a stalled connection. kill also reaps the child.
    pub fn close(self: *ReplaySession) void {
        self.client.deinit();
        self.child.kill(self.io);
        self.allocator.free(self.map_name);
    }
};

fn selectPlayer(players: []const protocol.PlayerInfoExtra, requested: ?u32) !u32 {
    // Observer 0 is a special SC2 perspective, not a participant listed in metadata.
    if (requested == 0) return 0;
    for (players) |extra| {
        const player = extra.player_info orelse continue;
        const id = player.player_id orelse continue;
        if (player.player_type == .observer) continue;
        if (requested) |wanted| {
            if (id == wanted) return id;
        } else return id;
    }
    return error.InvalidPlayer;
}

test "observer zero is special; participant selection still validates metadata" {
    const players = [_]protocol.PlayerInfoExtra{
        .{ .player_info = .{ .player_id = 9, .player_type = .observer } },
        .{ .player_info = .{ .player_id = 1, .player_type = .participant } },
        .{ .player_info = .{ .player_id = 2, .player_type = .participant } },
    };
    try std.testing.expectEqual(@as(u32, 0), try selectPlayer(&players, 0));
    try std.testing.expectEqual(@as(u32, 0), try selectPlayer(&.{}, 0));
    try std.testing.expectEqual(@as(u32, 1), try selectPlayer(&players, null));
    try std.testing.expectEqual(@as(u32, 2), try selectPlayer(&players, 2));
    try std.testing.expectError(error.InvalidPlayer, selectPlayer(&players, 3));
    try std.testing.expectError(error.InvalidPlayer, selectPlayer(&players, 9));
}

fn latestBuild(allocator: std.mem.Allocator, io: std.Io, installation: []const u8) !u32 {
    const path = try std.fs.path.join(allocator, &.{ installation, "Versions" });
    defer allocator.free(path);
    var dir = try std.Io.Dir.openDirAbsolute(io, path, .{ .iterate = true });
    defer dir.close(io);
    var iter = dir.iterate();
    var latest: u32 = 0;
    while (try iter.next(io)) |entry| {
        if (!std.mem.startsWith(u8, entry.name, "Base")) continue;
        latest = @max(latest, std.fmt.parseInt(u32, entry.name[4..], 10) catch continue);
    }
    if (latest == 0) return error.MissingSC2Binary;
    return latest;
}

fn launch(allocator: std.mem.Allocator, io: std.Io, config: ReplaySession.Config, build: u32) !std.process.Child {
    const binary = try std.fmt.allocPrint(allocator, "{s}/Versions/Base{d}/SC2_x64", .{ config.installation, build });
    defer allocator.free(binary);
    std.Io.Dir.accessAbsolute(io, binary, .{}) catch |err| {
        std.log.err("SC2 binary unavailable: {s} ({s})", .{ binary, @errorName(err) });
        return error.MissingSC2Binary;
    };
    const port = try std.fmt.allocPrint(allocator, "{d}", .{config.port});
    defer allocator.free(port);
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.appendSlice(allocator, &.{ binary, "-listen", "127.0.0.1", "-port", port, "-dataDir", config.installation });
    if (config.osmesa_path) |path| {
        try argv.appendSlice(allocator, &.{ "-osmesapath", path });
    } else if (config.egl_path) |path| {
        try argv.appendSlice(allocator, &.{ "-eglpath", path });
    }
    std.log.info("Launching {s}", .{binary});
    return std.process.spawn(io, .{
        .argv = argv.items,
        .stdout = if (config.verbose) .inherit else .ignore,
        .stderr = if (config.verbose) .inherit else .ignore,
    });
}

fn validatePlayerCount(players: []const protocol.PlayerInfoExtra, expected: usize) !void {
    var count: usize = 0;
    for (players, 0..) |extra, i| {
        const player = extra.player_info orelse continue;
        const id = player.player_id orelse continue;
        if (id == 0 or player.player_type == .observer) continue;
        for (players[0..i]) |prior| {
            const other = prior.player_info orelse continue;
            if (other.player_type != .observer and other.player_id == id) return error.DuplicatePlayerId;
        }
        count += 1;
    }
    if (count != expected) return error.UnsupportedPlayerCount;
}

test "participant restriction ignores observers and accepts sparse IDs, rejects other counts and duplicates" {
    const players = [_]protocol.PlayerInfoExtra{
        .{ .player_info = .{ .player_id = 9, .player_type = .observer } },
        .{ .player_info = .{ .player_id = 3, .player_type = .participant } },
        .{ .player_info = .{ .player_id = 7, .player_type = .participant } },
        .{ .player_info = .{ .player_id = 5, .player_type = .computer } },
    };
    try validatePlayerCount(players[0..3], 2);
    try std.testing.expectError(error.UnsupportedPlayerCount, validatePlayerCount(players[0..2], 2));
    try std.testing.expectError(error.UnsupportedPlayerCount, validatePlayerCount(&players, 2));
    try std.testing.expectError(error.DuplicatePlayerId, validatePlayerCount(&.{ players[1], players[1] }, 2));
}

fn connect(io: std.Io, port: u16, allocator: std.mem.Allocator) !Client {
    for (0..100) |_| {
        var client = Client.init(io, "127.0.0.1", port, allocator) catch |err| {
            if (err == error.Canceled) return err;
            try std.Io.sleep(io, .fromMilliseconds(200), .awake);
            continue;
        };
        errdefer client.deinit();
        try client.completeHandshake("/sc2api");
        return client;
    }
    std.log.err("SC2 did not open port {d}; use --verbose-sc2 to inspect startup errors", .{port});
    return error.SC2ConnectionTimeout;
}
