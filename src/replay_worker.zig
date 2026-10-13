const std = @import("std");
const sc2 = @import("zig-sc2");
const images = @import("image.zig");
const Playback = @import("playback.zig").Playback;
const player_labels = @import("player_labels.zig");
const data = @import("replay_data.zig");
const observation_data = @import("observation_data.zig");
const minimap_mapping = @import("minimap_mapping.zig");

pub const Camera = struct {
    x: f32,
    y: f32,
    distance: f32 = 40,

    pub fn zoom(self: *Camera, steps: f32) void {
        if (!std.math.isFinite(steps)) return;
        self.distance = std.math.clamp(self.distance - steps * 4, 10, 100);
    }
};
pub const Worker = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    config: sc2.ReplaySession.Config,
    initial_distance: f32 = 40,
    mutex: std.Io.Mutex = .init,
    pending: ?images.Frame = null,
    pending_chat: data.ChatQueue = .{},
    // Worker-only metadata; never borrowed by the GUI. Owned by runInner.
    terrain: ?observation_data.Terrain = null,
    production_catalog: ?@import("production_catalog.zig").Catalog = null,
    players: data.Players = .{},
    failure: ?anyerror = null,
    ready: bool = false,
    ended: bool = false,
    duration: u32 = 0,
    labels: player_labels.Labels = .{},
    map_width: f32 = 256,
    map_height: f32 = 256,
    minimap_mapping: minimap_mapping.Mapping = .{},
    camera: Camera = .{ .x = 128, .y = 128 },
    requested_camera: ?Camera = null,
    playback: Playback = .{},
    revision: u64 = 0,
    single_steps: u32 = 0,

    pub fn lock(self: *Worker) void {
        self.mutex.lockUncancelable(self.io);
    }
    pub fn unlock(self: *Worker) void {
        self.mutex.unlock(self.io);
    }

    /// Called by the GUI while holding the mutex. Camera requests coalesce.
    pub fn requestZoom(self: *Worker, steps: f32) void {
        if (!self.ready or self.ended) return;
        var camera = self.requested_camera orelse self.camera;
        camera.zoom(steps);
        self.requested_camera = camera;
    }

    /// Called by the GUI while holding the mutex. Snapshot before assigning the
    /// optional destination: reading it inside its own initializer can alias the
    /// payload Zig is still constructing (including its uninitialized distance).
    pub fn requestPosition(self: *Worker, x: f32, y: f32) void {
        if (!self.ready or self.ended) return;
        var camera = self.requested_camera orelse self.camera;
        camera.x = std.math.clamp(x, 0, self.map_width);
        camera.y = std.math.clamp(y, 0, self.map_height);
        self.requested_camera = camera;
    }

    /// Normalized square RGB minimap coordinates, including letterboxing.
    /// Called by the GUI while holding the mutex.
    pub fn requestMinimapPosition(self: *Worker, x: f32, y: f32) void {
        if (!std.math.isFinite(x) or !std.math.isFinite(y)) return;
        const point = self.minimap_mapping.toWorld(.{ .x = x, .y = y });
        self.requestPosition(point.x, point.y);
    }

    /// Atomically take the latest image and all queued events. Image replacement
    /// is allowed, but chat is retained independently until the GUI drains it.
    pub fn takeFrameAndChat(self: *Worker, history: *data.ChatQueue) ?images.Frame {
        self.lock();
        defer self.unlock();
        const frame = self.pending;
        self.pending = null;
        self.pending_chat.drainInto(history);
        return frame;
    }

    pub fn deinit(self: *Worker) void {
        if (self.pending) |f| f.deinit(self.allocator);
    }

    pub fn run(self: *Worker) std.Io.Cancelable!void {
        self.runInner() catch |err| {
            if (err == error.Canceled) return error.Canceled;
            std.log.err("Replay worker: {s}. Check game version/map dependencies; for rendering errors try --verbose-sc2 or --osmesa PATH.", .{@errorName(err)});
            self.lock();
            defer self.unlock();
            self.failure = err;
        };
    }

    fn runInner(self: *Worker) !void {
        var permanent = std.heap.ArenaAllocator.init(self.allocator);
        defer permanent.deinit();
        var responses = std.heap.ArenaAllocator.init(self.allocator);
        defer responses.deinit();
        var session = try sc2.ReplaySession.open(permanent.allocator(), self.io, self.config, responses.allocator());
        defer session.close();
        self.production_catalog = try @import("production_catalog.zig").Catalog.init(self.allocator, try session.client.getGameData());
        defer {
            self.production_catalog.?.deinit(self.allocator);
            self.production_catalog = null;
        }
        const game_info = try session.client.getGameInfo();
        const mapping = minimap_mapping.Mapping.fromPlayable(if (game_info.start_raw) |raw| raw.playable_area else null, session.map_width, session.map_height);
        if (game_info.start_raw) |raw| {
            if (raw.terrain_height) |height| self.terrain = try observation_data.Terrain.copy(self.allocator, height);
        }
        defer {
            if (self.terrain) |terrain| terrain.deinit(self.allocator);
            self.terrain = null;
        }
        var players: data.Players = .{};
        for (session.players[0..session.player_count]) |player| {
            players.add(player.id, std.mem.sliceTo(&player.name, 0));
        }
        self.lock();
        self.players = players;
        self.unlock();
        var obs = try session.observe();
        // This first observation is used for camera placement, not displayed,
        // but any chat it contains must still survive the response arena reset.
        self.lock();
        appendChat(&self.pending_chat, obs);
        self.unlock();
        const labels = player_labels.capture(session.players[0..session.player_count], obs, mapping);
        var camera = initialCamera(obs, session.map_width, session.map_height);
        camera.distance = self.initial_distance;
        try session.client.setObserverCamera(camera.x, camera.y, camera.distance);
        _ = responses.reset(.retain_capacity);
        obs = try session.observe();
        try self.publish(obs, session.client.status, camera);
        self.lock();
        self.labels = labels;
        self.duration = session.duration_loops;
        self.map_width = session.map_width;
        self.map_height = session.map_height;
        self.minimap_mapping = mapping;
        self.camera = camera;
        self.ready = true;
        self.unlock();
        _ = responses.reset(.retain_capacity);

        var scheduler: Playback = .{};
        var revision: u64 = 0;
        var last = std.Io.Clock.awake.now(self.io);
        while (true) {
            const now = std.Io.Clock.awake.now(self.io);
            var elapsed = @as(f64, @floatFromInt(now.nanoseconds - last.nanoseconds)) / 1e9;
            last = now;
            self.lock();
            if (revision != self.revision) {
                scheduler = self.playback;
                revision = self.revision;
                elapsed = 0;
            }
            const ended = self.ended;
            const step_once = self.single_steps > 0 and scheduler.paused and !ended;
            if (step_once) self.single_steps -= 1;
            // Observer actions are not valid once SC2 has transitioned to ended.
            const move = if (ended) null else self.requested_camera;
            self.requested_camera = null;
            // Expose the submitted target before I/O so GUI movement keeps accumulating
            // from it while SC2 is busy, rather than restarting from an older position.
            if (move) |position| self.camera = position;
            self.unlock();
            const count = if (ended) 0 else if (step_once) 1 else scheduler.due(elapsed);
            if (move) |position| {
                try session.client.setObserverCamera(position.x, position.y, position.distance);
                camera = position;
            }
            if (count > 0) try session.advance(count);
            if (count > 0 or move != null) {
                obs = try session.observe();
                try self.publish(obs, session.client.status, camera);
                _ = responses.reset(.retain_capacity);
            } else try std.Io.sleep(self.io, .fromMilliseconds(5), .awake);
        }
    }

    fn publish(self: *Worker, obs: sc2.sc2p.ResponseObservation, status: sc2.sc2p.Status, camera: Camera) !void {
        const frame = try images.Frame.fromObservationWithContext(self.allocator, obs, status, .{
            .camera = .{ .x = camera.x, .y = camera.y, .distance = camera.distance },
            .terrain = if (self.terrain) |*terrain| terrain else null,
            .production_catalog = if (self.production_catalog) |*catalog| catalog else null,
        });
        self.lock();
        const old = self.pending;
        appendChat(&self.pending_chat, obs);
        self.pending = frame;
        self.ended = frame.ended;
        self.unlock();
        if (old) |f| f.deinit(self.allocator);
    }
};

fn appendChat(queue: *data.ChatQueue, obs: sc2.sc2p.ResponseObservation) void {
    const loop = if (obs.observation) |o| o.game_loop orelse 0 else 0;
    for (obs.chat orelse &.{}) |message| {
        queue.push(data.ChatMessage.init(message.player_id orelse 0, loop, message.message orelse ""));
    }
}

test "observation chat is copied before reset, including initial and empty messages" {
    var queue: data.ChatQueue = .{};
    var text_bytes = [_]u8{ 'g', 'l', 'h', 'f' };
    var initial = [_]sc2.sc2p.ChatReceived{.{ .player_id = 1, .message = &text_bytes }};
    appendChat(&queue, .{ .observation = .{ .game_loop = 0 }, .chat = &initial });
    @memset(&text_bytes, 'x');
    var later = [_]sc2.sc2p.ChatReceived{ .{ .player_id = 2, .message = "hi" }, .{} };
    appendChat(&queue, .{ .observation = .{ .game_loop = 32 }, .chat = &later });
    try std.testing.expectEqual(@as(usize, 3), queue.count);
    try std.testing.expectEqualStrings("glhf", queue.at(0).text());
    try std.testing.expectEqual(@as(u32, 32), queue.at(1).game_loop);
    try std.testing.expectEqual(@as(u32, 0), queue.at(2).player_id);
    try std.testing.expectEqualStrings("", queue.at(2).text());
}

pub fn initialCamera(obs: sc2.sc2p.ResponseObservation, width: f32, height: f32) Camera {
    if (obs.observation) |observation| {
        if (observation.raw) |raw| {
            for (raw.units) |unit| {
                // In perspective 0, resources can be classified as self while
                // participant units are neutral. Ownership identifies the players.
                if (unit.owner > 0 and unit.owner < 16 and unit.alliance == .self)
                    return .{ .x = unit.position.x, .y = unit.position.y };
            }
            for (raw.units) |unit| {
                if (unit.owner > 0 and unit.owner < 16)
                    return .{ .x = unit.position.x, .y = unit.position.y };
            }
        }
    }
    return .{ .x = width / 2, .y = height / 2 };
}

test "replacing image frames does not replace queued chat" {
    var worker: Worker = .{ .io = std.testing.io, .allocator = std.testing.allocator, .config = .{ .installation = "", .replay = "" } };
    defer worker.deinit();
    var history: data.ChatQueue = .{};
    var heights: [4]u8 = @splat(223);
    worker.terrain = .{ .width = 2, .height = 2, .bytes = &heights };
    const submitted: Camera = .{ .x = 0.5, .y = 0.5, .distance = 40 };
    var units = [_]sc2.sc2p.Unit{.{ .tag = 1, .position = .{ .x = 0.4, .y = 0.4 }, .z = 12 }};
    var pixels = [_]u8{ 10, 20, 30 };
    var messages = [_]sc2.sc2p.ChatReceived{.{ .player_id = 1, .message = "first" }};
    var obs: sc2.sc2p.ResponseObservation = .{
        .observation = .{ .game_loop = 1, .raw = .{ .units = &units }, .render = .{ .map = .{ .bits_per_pixel = 24, .size = .{ .x = 1, .y = 1 }, .image = &pixels } } },
        .chat = &messages,
    };
    try worker.publish(obs, .in_replay, submitted);
    messages[0].message = "second";
    obs.observation.?.game_loop = 2;
    units[0].position.x = 0.9;
    worker.camera.distance = 80; // GUI-facing command state can be ahead of RGB.
    try worker.publish(obs, .in_replay, submitted);
    units[0].position.x = 1.8; // Response arena may immediately be reused.
    const frame = worker.takeFrameAndChat(&history).?;
    defer frame.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 2), frame.game_loop);
    try std.testing.expectEqual(@as(f32, 40), frame.scene.camera.?.distance);
    try std.testing.expectEqual(@as(f32, 0.9), frame.scene.find(1).?.position.x);
    try std.testing.expectEqual(@as(usize, 2), history.count);
    try std.testing.expectEqualStrings("first", history.at(0).text());
    try std.testing.expectEqualStrings("second", history.at(1).text());
    try std.testing.expect(worker.takeFrameAndChat(&history) == null);
    try std.testing.expectEqual(@as(usize, 2), history.count);
}

test "minimap positioning preserves current and pending zoom before scrolling" {
    var worker: Worker = .{ .io = undefined, .allocator = std.testing.allocator, .config = .{ .installation = "", .replay = "" } };
    worker.ready = true;
    worker.camera.distance = 80;
    worker.requestPosition(100, 120);
    try std.testing.expectEqual(@as(f32, 80), worker.requested_camera.?.distance);
    worker.requestZoom(1);
    try std.testing.expectEqual(@as(f32, 76), worker.requested_camera.?.distance);
    worker.requestPosition(50, 60);
    try std.testing.expectEqual(@as(f32, 76), worker.requested_camera.?.distance);
    try std.testing.expectEqual(@as(f32, 50), worker.requested_camera.?.x);
    try std.testing.expectEqual(@as(f32, 60), worker.requested_camera.?.y);
}

test "minimap base clicks use playable bounds and preserve pending zoom" {
    var worker: Worker = .{ .io = undefined, .allocator = std.testing.allocator, .config = .{ .installation = "", .replay = "" } };
    worker.ready = true;
    worker.map_width = 160;
    worker.map_height = 208;
    worker.minimap_mapping = minimap_mapping.Mapping.fromPlayable(.{ .p0 = .{ .x = 14, .y = 32 }, .p1 = .{ .x = 142, .y = 176 } }, 160, 208);
    worker.camera.distance = 80;
    worker.requestZoom(1);
    worker.requestMinimapPosition(105.33333 / 128.0, 1 - 14.66667 / 128.0);
    try std.testing.expectApproxEqAbs(@as(f32, 124.5), worker.requested_camera.?.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 159.5), worker.requested_camera.?.y, 0.001);
    try std.testing.expectEqual(@as(f32, 76), worker.requested_camera.?.distance);
    const pending = worker.requested_camera;
    worker.requestMinimapPosition(std.math.nan(f32), 0.5);
    try std.testing.expectEqual(pending, worker.requested_camera);
    worker.ended = true;
    worker.requestMinimapPosition(0.5, 0.5);
    try std.testing.expectEqual(pending, worker.requested_camera);
}

test "zoom requests coalesce, preserve position, clamp and stop at replay end" {
    var worker: Worker = .{ .io = undefined, .allocator = std.testing.allocator, .config = .{ .installation = "", .replay = "" } };
    worker.requestZoom(1);
    try std.testing.expect(worker.requested_camera == null);
    worker.ready = true;
    worker.requestZoom(1);
    worker.requestZoom(2);
    try std.testing.expectEqual(@as(f32, 28), worker.requested_camera.?.distance);
    try std.testing.expectEqual(worker.camera.x, worker.requested_camera.?.x);
    worker.requestZoom(100);
    try std.testing.expectEqual(@as(f32, 10), worker.requested_camera.?.distance);
    worker.requestZoom(-100);
    try std.testing.expectEqual(@as(f32, 100), worker.requested_camera.?.distance);
    worker.ended = true;
    worker.requested_camera = null;
    worker.requestZoom(1);
    try std.testing.expect(worker.requested_camera == null);
}

test "observer initial camera chooses a participant, not self-classified resources" {
    var units = [_]sc2.sc2p.Unit{
        .{ .owner = 16, .alliance = .self, .position = .{ .x = 90, .y = 100 } },
        .{ .owner = 1, .alliance = .neutral, .position = .{ .x = 20, .y = 30 } },
        .{ .owner = 2, .alliance = .neutral, .position = .{ .x = 120, .y = 140 } },
    };
    const camera = initialCamera(.{ .observation = .{ .raw = .{ .units = &units } } }, 160, 208);
    try std.testing.expectEqual(@as(f32, 20), camera.x);
    try std.testing.expectEqual(@as(f32, 30), camera.y);
}

test "initial camera prefers observed player's units" {
    var units = [_]sc2.sc2p.Unit{
        .{ .owner = 1, .alliance = .enemy, .position = .{ .x = 20, .y = 30 } },
        .{ .owner = 2, .alliance = .self, .position = .{ .x = 120, .y = 140 } },
    };
    const camera = initialCamera(.{ .observation = .{ .raw = .{ .units = &units } } }, 160, 208);
    try std.testing.expectEqual(@as(f32, 120), camera.x);
    try std.testing.expectEqual(@as(f32, 140), camera.y);
}
