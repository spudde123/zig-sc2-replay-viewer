const std = @import("std");
pub const std_options: std.Options = .{ .log_level = .info };
const sokol = @import("sokol");
const sc2 = @import("zig-sc2");
const cli = @import("cli.zig");
const images = @import("image.zig");
const replay = @import("replay_worker.zig");
const Renderer = @import("renderer.zig").Renderer;

// Signal handlers only touch a lock-free atomic; cleanup runs on the normal thread.
var interrupted = std.atomic.Value(bool).init(false);
fn handleSignal(_: std.posix.SIG) callconv(.c) void {
    interrupted.store(true, .release);
}

const App = struct {
    worker: replay.Worker,
    options: cli.Options,
    renderer: Renderer = undefined,
    current: ?images.Frame = null,
    elapsed: f64 = 0,
    failed: bool = false,

    fn fromUserdata(ptr: ?*anyopaque) *App {
        return @ptrCast(@alignCast(ptr.?));
    }

    fn init(ptr: ?*anyopaque) callconv(.c) void {
        fromUserdata(ptr).renderer = Renderer.init();
    }

    fn frame(ptr: ?*anyopaque) callconv(.c) void {
        const self = fromUserdata(ptr);
        if (self.worker.takeFrame()) |next| {
            if (self.current) |old| old.deinit(self.worker.allocator);
            self.current = next;
        }
        self.elapsed += sokol.app.frameDuration();
        self.worker.lock();
        const failure = self.worker.failure;
        const ready = self.worker.ready;
        const ended = self.worker.ended;
        const speed = self.worker.playback.speed();
        const paused = self.worker.playback.paused;
        const duration = self.worker.duration;
        const labels = self.worker.labels;
        self.worker.unlock();
        if (interrupted.load(.acquire)) sokol.app.requestQuit();
        if (failure != null) {
            self.failed = true;
            sokol.app.requestQuit();
        }
        if (self.options.quit_after) |limit| {
            if (self.elapsed >= limit) sokol.app.requestQuit();
        }
        self.renderer.draw(self.current, .{
            .duration_loops = duration,
            .labels = labels,
            .speed = speed,
            .state = if (ended) .ended else if (!ready) .loading else if (paused) .paused else .playing,
        });
    }

    fn cleanup(ptr: ?*anyopaque) callconv(.c) void {
        fromUserdata(ptr).renderer.deinit();
    }

    fn event(ev: [*c]const sokol.app.Event, ptr: ?*anyopaque) callconv(.c) void {
        const self = fromUserdata(ptr);
        self.worker.lock();
        defer self.worker.unlock();
        if (ev.*.type == .KEY_DOWN) {
            if (ev.*.key_code == .ESCAPE) {
                sokol.app.requestQuit();
                return;
            }
            if (ev.*.key_repeat and (ev.*.key_code == .SPACE or ev.*.key_code == .LEFT_BRACKET or ev.*.key_code == .RIGHT_BRACKET or ev.*.key_code == .UP or ev.*.key_code == .DOWN)) return;
            switch (ev.*.key_code) {
                .SPACE => {
                    self.worker.playback.setPaused(!self.worker.playback.paused);
                    self.worker.single_steps = 0;
                    self.worker.revision += 1;
                },
                .LEFT_BRACKET, .RIGHT_BRACKET, .UP, .DOWN => {
                    self.worker.playback.changeSpeed(ev.*.key_code == .RIGHT_BRACKET or ev.*.key_code == .UP);
                    self.worker.revision += 1;
                },
                .RIGHT => if (self.worker.playback.paused and !self.worker.ended) {
                    self.worker.single_steps = @min(32, self.worker.single_steps + 1);
                },
                .W, .A, .S, .D => {
                    var camera = self.worker.requested_camera orelse self.worker.camera;
                    switch (ev.*.key_code) {
                        .W => camera.y += 8,
                        .S => camera.y -= 8,
                        .A => camera.x -= 8,
                        .D => camera.x += 8,
                        else => unreachable,
                    }
                    camera.x = std.math.clamp(camera.x, 0, self.worker.map_width);
                    camera.y = std.math.clamp(camera.y, 0, self.worker.map_height);
                    self.worker.requested_camera = camera;
                },
                else => {},
            }
        } else if (ev.*.type == .MOUSE_DOWN and ev.*.mouse_button == .LEFT and self.worker.ready) {
            // Sokol mouse coordinates and framebuffer coordinates are both physical pixels.
            const rect = self.renderer.minimap_rect;
            if (rect.contains(ev.*.mouse_x, ev.*.mouse_y)) {
                self.worker.requested_camera = .{
                    .x = (ev.*.mouse_x - rect.x) / rect.width * self.worker.map_width,
                    .y = (1 - (ev.*.mouse_y - rect.y) / rect.height) * self.worker.map_height,
                };
            }
        }
    }
};

pub fn main(init: std.process.Init) void {
    run(init) catch |err| {
        std.log.err("{s}", .{@errorName(err)});
        std.process.exit(1);
    };
}

fn run(init: std.process.Init) !void {
    const action: std.posix.Sigaction = .{ .handler = .{ .handler = handleSignal }, .mask = std.posix.sigemptyset(), .flags = 0 };
    var old_int: std.posix.Sigaction = undefined;
    var old_term: std.posix.Sigaction = undefined;
    std.posix.sigaction(.INT, &action, &old_int);
    std.posix.sigaction(.TERM, &action, &old_term);
    defer std.posix.sigaction(.INT, &old_int, null);
    defer std.posix.sigaction(.TERM, &old_term, null);
    const allocator = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var options = cli.parse(args) catch |err| {
        std.debug.print("{s}", .{cli.usage});
        if (err == error.HelpRequested) return;
        return err;
    };
    options.session.replay = std.Io.Dir.cwd().realPathFileAlloc(init.io, options.session.replay, init.arena.allocator()) catch |err| {
        std.log.err("Replay path unavailable: {s}", .{options.session.replay});
        return err;
    };
    options.session.installation = std.Io.Dir.cwd().realPathFileAlloc(init.io, options.session.installation, init.arena.allocator()) catch |err| {
        std.log.err("SC2 installation unavailable: {s}", .{options.session.installation});
        return err;
    };
    if (options.session.osmesa_path orelse options.session.egl_path) |library| {
        std.Io.Dir.accessAbsolute(init.io, library, .{}) catch |err| {
            std.log.err("Rendering library unavailable: {s}", .{library});
            return err;
        };
    }
    if (options.probe) return probe(allocator, init.io, options);

    var app: App = .{
        .worker = .{ .io = init.io, .allocator = allocator, .config = options.session },
        .options = options,
    };
    defer {
        if (app.current) |f| f.deinit(allocator);
        app.worker.deinit();
    }
    var group: std.Io.Group = .init;
    try group.concurrent(init.io, replay.Worker.run, .{&app.worker});
    // Cancels socket reads/startup sleeps and waits for the worker's deferred child cleanup.
    defer group.cancel(init.io);
    sokol.app.run(.{
        .user_data = &app,
        .init_userdata_cb = App.init,
        .frame_userdata_cb = App.frame,
        .cleanup_userdata_cb = App.cleanup,
        .event_userdata_cb = App.event,
        .width = 960,
        .height = 720,
        .window_title = "SC2 replay",
        .high_dpi = true,
        .logger = .{ .func = sokol.log.func },
    });
    if (app.options.capture) |path| {
        if (app.current) |f| try f.map.writePpm(allocator, init.io, path) else return error.NoFrameReceived;
    }
    if (app.failed) return error.ReplayFailed;
}

const ProbeTask = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    options: cli.Options,
    result: ?anyerror = null,
    done: std.atomic.Value(bool) = .init(false),

    fn run(self: *ProbeTask) std.Io.Cancelable!void {
        renderProbe(self.allocator, self.io, self.options) catch |err| {
            self.result = err;
            self.done.store(true, .release);
            if (err == error.Canceled) return error.Canceled;
            return;
        };
        self.done.store(true, .release);
    }
};

fn probe(allocator: std.mem.Allocator, io: std.Io, options: cli.Options) !void {
    var task: ProbeTask = .{ .allocator = allocator, .io = io, .options = options };
    var group: std.Io.Group = .init;
    try group.concurrent(io, ProbeTask.run, .{&task});
    defer group.cancel(io);
    while (!task.done.load(.acquire)) {
        if (interrupted.load(.acquire)) return error.Interrupted;
        try std.Io.sleep(io, .fromMilliseconds(50), .awake);
    }
    if (task.result) |err| return err;
}

fn renderProbe(allocator: std.mem.Allocator, io: std.Io, options: cli.Options) !void {
    var permanent = std.heap.ArenaAllocator.init(allocator);
    defer permanent.deinit();
    var responses = std.heap.ArenaAllocator.init(allocator);
    defer responses.deinit();
    var session = try sc2.ReplaySession.open(permanent.allocator(), io, options.session, responses.allocator());
    defer session.close();
    const first = try session.observe();
    const camera = replay.initialCamera(first, session.map_width, session.map_height);
    try session.client.moveObserverCamera(camera.x, camera.y);
    _ = responses.reset(.retain_capacity);
    var loops = options.probe_loops;
    while (loops > 0 and session.client.status != .ended) {
        const batch = @min(loops, 32);
        try session.advance(batch);
        loops -= batch;
        _ = responses.reset(.retain_capacity);
    }
    const obs = try session.observe();
    const frame = try images.Frame.fromObservation(allocator, obs, session.client.status);
    defer frame.deinit(allocator);
    std.log.info("Rendered {d}x{d}, loop {d}, RGBA hash {x}, minimap {s}, ended={}", .{
        frame.map.width,                           frame.map.height,                                   frame.game_loop,
        std.hash.Wyhash.hash(0, frame.map.pixels), if (frame.minimap != null) "present" else "absent", frame.ended,
    });
    if (options.capture) |path| try frame.map.writePpm(allocator, io, path);
}
