const std = @import("std");
pub const std_options: std.Options = .{ .log_level = .info };
const sokol = @import("sokol");
const sc2 = @import("zig-sc2");
const cli = @import("cli.zig");
const images = @import("replay/image.zig");
const replay = @import("replay/replay_worker.zig");
const Renderer = @import("ui/renderer.zig").Renderer;
const keybinds = @import("input/keybinds.zig");
const projection = @import("camera/camera_projection.zig");

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
    pan: @import("input/camera_pan.zig").Pan = .{},
    bindings: keybinds.Keybinds = .{},
    minimap_drag: @import("input/minimap_drag.zig").Drag = .{},
    chat: @import("replay/replay_data.zig").ChatQueue = .{},
    chat_visible: bool = false,
    production_visible: bool = true,
    selected_tag: ?u64 = null,

    fn fromUserdata(ptr: ?*anyopaque) *App {
        return @ptrCast(@alignCast(ptr.?));
    }

    fn init(ptr: ?*anyopaque) callconv(.c) void {
        fromUserdata(ptr).renderer = Renderer.init();
    }

    fn frame(ptr: ?*anyopaque) callconv(.c) void {
        const self = fromUserdata(ptr);
        const update = self.worker.takeFrameAndChat(&self.chat);
        if (update.new_chat) self.chat_visible = true;
        if (update.frame) |next| {
            if (self.current) |old| old.deinit(self.worker.allocator);
            self.current = next;
            if (self.selected_tag) |tag| {
                const unit = next.scene.find(tag);
                if (unit == null or !unit.?.visible) self.selected_tag = null;
            }
        }
        const dt = sokol.app.frameDuration();
        self.elapsed += dt;
        self.worker.lock();
        if (self.worker.ready and !self.worker.ended and !self.minimap_drag.active) {
            var camera = self.worker.requested_camera orelse self.worker.camera;
            if (self.pan.apply(&camera, dt, self.worker.map_width, self.worker.map_height)) {
                self.worker.requestCamera(camera);
            }
        }
        const failure = self.worker.failure;
        const ready = self.worker.ready;
        const ended = self.worker.ended;
        const speed = self.worker.playback.speed();
        const paused = self.worker.playback.paused;
        const duration = self.worker.duration;
        const labels = self.worker.labels;
        const players = self.worker.players;
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
        }, .{
            .players = &players,
            .chat = &self.chat,
            .chat_visible = self.chat_visible,
            .production_visible = self.production_visible,
            .selected_tag = self.selected_tag,
            .projection_markers = self.options.projection_markers,
        });
    }

    fn cleanup(ptr: ?*anyopaque) callconv(.c) void {
        fromUserdata(ptr).renderer.deinit();
    }

    fn event(ev: [*c]const sokol.app.Event, ptr: ?*anyopaque) callconv(.c) void {
        const self = fromUserdata(ptr);
        // GUI-only controls work while loading, paused, and after replay end.
        // Consume the click before it can reach camera/minimap handling.
        if (ev.*.type == .MOUSE_DOWN and ev.*.mouse_button == .LEFT and
            self.renderer.chat_button_rect.contains(ev.*.mouse_x, ev.*.mouse_y))
        {
            self.chat_visible = !self.chat_visible;
            return;
        }
        if (ev.*.type == .MOUSE_DOWN and ev.*.mouse_button == .LEFT and
            self.renderer.production_button_rect.contains(ev.*.mouse_x, ev.*.mouse_y))
        {
            self.production_visible = !self.production_visible;
            return;
        }
        if (ev.*.type == .MOUSE_DOWN and ev.*.mouse_button == .RIGHT) {
            self.selected_tag = null;
            return;
        }
        if (ev.*.type == .MOUSE_DOWN and ev.*.mouse_button == .LEFT) {
            if (self.renderer.blocksWorldClick(ev.*.mouse_x, ev.*.mouse_y)) return;
            if (!self.renderer.minimap_rect.contains(ev.*.mouse_x, ev.*.mouse_y)) {
                if (self.current) |current| self.selected_tag = projection.pick(&current.scene, self.renderer.map_rect, @floatFromInt(current.map.width), @floatFromInt(current.map.height), ev.*.mouse_x, ev.*.mouse_y);
                return;
            }
        }
        if (ev.*.type == .MOUSE_SCROLL and self.renderer.blocksWorldClick(ev.*.mouse_x, ev.*.mouse_y)) return;
        if (ev.*.type == .UNFOCUSED) {
            // Key releases may be delivered elsewhere after losing focus.
            self.pan.clear();
            self.minimap_drag.end();
            return;
        }
        if (ev.*.type == .MOUSE_UP and ev.*.mouse_button == .LEFT) {
            self.minimap_drag.end();
            return;
        }
        if (ev.*.type == .MOUSE_LEAVE) {
            // Avoid a stuck drag if the release happens outside this window.
            self.minimap_drag.end();
            return;
        }
        if (ev.*.type == .KEY_DOWN or ev.*.type == .KEY_UP) {
            if (self.pan.setKey(ev.*.key_code, ev.*.type == .KEY_DOWN)) return;
        }
        if (ev.*.type == .KEY_DOWN and self.bindings.actionFor(ev.*.key_code) == .toggle_chat) {
            if (!ev.*.key_repeat) self.chat_visible = !self.chat_visible;
            return;
        }
        if (ev.*.type == .KEY_DOWN and self.bindings.actionFor(ev.*.key_code) == .toggle_production) {
            if (!ev.*.key_repeat) self.production_visible = !self.production_visible;
            return;
        }
        self.worker.lock();
        defer self.worker.unlock();
        if (ev.*.type == .KEY_DOWN) {
            const action = self.bindings.actionFor(ev.*.key_code) orelse return;
            if (ev.*.key_repeat and !action.acceptsRepeat()) return;
            switch (action) {
                .quit => sokol.app.requestQuit(),
                .pause => {
                    self.worker.playback.setPaused(!self.worker.playback.paused);
                    self.worker.single_steps = 0;
                    self.worker.revision += 1;
                },
                .speed_down, .speed_up => {
                    self.worker.playback.changeSpeed(action == .speed_up);
                    self.worker.revision += 1;
                },
                .step => if (self.worker.playback.paused and !self.worker.ended) {
                    self.worker.single_steps = @min(32, self.worker.single_steps + 1);
                },
                .zoom_in => self.worker.requestZoom(1),
                .zoom_out => self.worker.requestZoom(-1),
                else => {},
            }
        } else if (ev.*.type == .MOUSE_SCROLL) {
            self.worker.requestZoom(ev.*.scroll_y);
        } else if (ev.*.type == .MOUSE_DOWN and ev.*.mouse_button == .LEFT and self.worker.ready and !self.worker.ended) {
            // Sokol mouse coordinates and framebuffer coordinates are both physical pixels.
            const rect = self.renderer.minimap_rect;
            if (self.minimap_drag.begin(rect, ev.*.mouse_x, ev.*.mouse_y)) |point| {
                self.worker.requestMinimapPosition(point.x, point.y);
            }
        } else if (ev.*.type == .MOUSE_MOVE) {
            if (self.minimap_drag.update(self.renderer.minimap_rect, ev.*.mouse_x, ev.*.mouse_y)) |point| {
                self.worker.requestMinimapPosition(point.x, point.y);
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

    const bindings = keybinds.load(allocator, init.io);
    var app: App = .{
        .worker = .{ .io = init.io, .allocator = allocator, .config = options.session, .initial_distance = options.camera_distance },
        .options = options,
        .bindings = bindings,
        .pan = .{ .bindings = bindings },
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
    try session.client.setObserverCamera(camera.x, camera.y, options.camera_distance);
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
