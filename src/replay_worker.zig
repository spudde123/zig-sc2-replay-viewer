const std = @import("std");
const sc2 = @import("zig-sc2");
const images = @import("image.zig");
const Playback = @import("playback.zig").Playback;

pub const Camera = struct { x: f32, y: f32 };
pub const Worker = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    config: sc2.ReplaySession.Config,
    mutex: std.Io.Mutex = .init,
    pending: ?images.Frame = null,
    failure: ?anyerror = null,
    ready: bool = false,
    ended: bool = false,
    duration: u32 = 0,
    map_width: f32 = 256,
    map_height: f32 = 256,
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

    pub fn takeFrame(self: *Worker) ?images.Frame {
        self.lock();
        defer self.unlock();
        const frame = self.pending;
        self.pending = null;
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
        var obs = try session.observe();
        const camera = initialCamera(obs, session.map_width, session.map_height);
        try session.client.moveObserverCamera(camera.x, camera.y);
        _ = responses.reset(.retain_capacity);
        obs = try session.observe();
        try self.publish(obs, session.client.status);
        self.lock();
        self.duration = session.duration_loops;
        self.map_width = session.map_width;
        self.map_height = session.map_height;
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
            self.unlock();
            const count = if (ended) 0 else if (step_once) 1 else scheduler.due(elapsed);
            if (move) |position| {
                try session.client.moveObserverCamera(position.x, position.y);
                self.lock();
                self.camera = position;
                self.unlock();
            }
            if (count > 0) try session.advance(count);
            if (count > 0 or move != null) {
                obs = try session.observe();
                try self.publish(obs, session.client.status);
                _ = responses.reset(.retain_capacity);
            } else try std.Io.sleep(self.io, .fromMilliseconds(5), .awake);
        }
    }

    fn publish(self: *Worker, obs: sc2.sc2p.ResponseObservation, status: sc2.sc2p.Status) !void {
        const frame = try images.Frame.fromObservation(self.allocator, obs, status);
        self.lock();
        const old = self.pending;
        self.pending = frame;
        self.ended = frame.ended;
        self.unlock();
        if (old) |f| f.deinit(self.allocator);
    }
};

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
