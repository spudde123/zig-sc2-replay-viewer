const std = @import("std");
const Keycode = @import("sokol").app.Keycode;

pub const filename = "keybinds.conf";
pub const Action = enum {
    pause,
    speed_up,
    speed_down,
    step,
    zoom_in,
    zoom_out,
    quit,
    pan_up,
    pan_left,
    pan_down,
    pan_right,
    toggle_chat,
    toggle_production,

    pub fn isPan(self: Action) bool {
        return switch (self) {
            .pan_up, .pan_left, .pan_down, .pan_right => true,
            else => false,
        };
    }

    pub fn acceptsRepeat(self: Action) bool {
        return switch (self) {
            .zoom_in, .zoom_out, .step => true,
            else => false,
        };
    }
};

const action_count = @typeInfo(Action).@"enum".field_names.len;
const Binding = struct {
    keys: [4]Keycode = @splat(.INVALID),
    count: usize = 0,
};
fn binding(comptime keys: []const Keycode) Binding {
    var result: Binding = .{ .count = keys.len };
    for (keys, 0..) |key, i| result.keys[i] = key;
    return result;
}

pub const Keybinds = struct {
    bindings: [action_count]Binding = .{
        binding(&.{.SPACE}),
        binding(&.{ .UP, .RIGHT_BRACKET }),
        binding(&.{ .DOWN, .LEFT_BRACKET }),
        binding(&.{.RIGHT}),
        binding(&.{ .EQUAL, .KP_ADD }),
        binding(&.{ .MINUS, .KP_SUBTRACT }),
        binding(&.{.ESCAPE}),
        binding(&.{.W}),
        binding(&.{.A}),
        binding(&.{.S}),
        binding(&.{.D}),
        binding(&.{.C}),
        binding(&.{.P}),
    },

    pub fn keys(self: *const Keybinds, action: Action) []const Keycode {
        const value = &self.bindings[@backingInt(action)];
        return value.keys[0..value.count];
    }

    pub fn actionFor(self: *const Keybinds, key: Keycode) ?Action {
        for (self.bindings, 0..) |value, i| {
            for (value.keys[0..value.count]) |candidate| {
                if (candidate == key) return @fromBackingInt(@intCast(i));
            }
        }
        return null;
    }

    pub fn primaryName(self: *const Keybinds, action: Action) []const u8 {
        const values = self.keys(action);
        return if (values.len == 0) "None" else @tagName(values[0]);
    }

    pub fn formatHints(self: *const Keybinds, buffer: []u8) std.mem.PrintError![]const u8 {
        return std.fmt.bufPrint(buffer, "{s} pause | {s}/{s} speed | {s}/{s}/{s}/{s} pan\nWheel or {s}/{s} zoom | {s} step | {s} quit | {s} chat | {s} production", .{
            self.primaryName(.pause),             self.primaryName(.speed_up), self.primaryName(.speed_down),
            self.primaryName(.pan_up),            self.primaryName(.pan_left), self.primaryName(.pan_down),
            self.primaryName(.pan_right),         self.primaryName(.zoom_in),  self.primaryName(.zoom_out),
            self.primaryName(.step),              self.primaryName(.quit),     self.primaryName(.toggle_chat),
            self.primaryName(.toggle_production),
        });
    }
};

fn parseAction(name: []const u8) !Action {
    inline for (@typeInfo(Action).@"enum".field_names) |field| {
        if (std.ascii.eqlIgnoreCase(name, field)) return @field(Action, field);
    }
    return error.UnknownAction;
}

fn parseKey(name: []const u8) !Keycode {
    if (std.mem.eql(u8, name, "+") or std.mem.eql(u8, name, "=")) return .EQUAL;
    if (std.mem.eql(u8, name, "-")) return .MINUS;
    if (std.mem.eql(u8, name, "[")) return .LEFT_BRACKET;
    if (std.mem.eql(u8, name, "]")) return .RIGHT_BRACKET;
    if (name.len == 1 and name[0] >= '0' and name[0] <= '9') return @fromBackingInt(@intCast(name[0]));
    inline for (@typeInfo(Keycode).@"enum".field_names) |field| {
        if (!std.mem.eql(u8, field, "INVALID") and std.ascii.eqlIgnoreCase(name, field)) return @field(Keycode, field);
    }
    return error.UnknownKey;
}

/// Partial overrides are merged into defaults, but any invalid line or conflict
/// rejects the whole file. Parsing has no allocations or externally visible changes.
pub fn parse(contents: []const u8) !Keybinds {
    var result: Keybinds = .{};
    var seen: [action_count]bool = @splat(false);
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |original| {
        const comment = std.mem.indexOfScalar(u8, original, '#') orelse original.len;
        const line = std.mem.trim(u8, original[0..comment], " \t\r");
        if (line.len == 0) continue;
        const equals = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidLine;
        const action = try parseAction(std.mem.trim(u8, line[0..equals], " \t"));
        const index = @backingInt(action);
        if (seen[index]) return error.DuplicateAction;
        seen[index] = true;
        const value = std.mem.trim(u8, line[equals + 1 ..], " \t");
        var replacement: Binding = .{};
        if (!std.ascii.eqlIgnoreCase(value, "none")) {
            var names = std.mem.splitScalar(u8, value, ',');
            while (names.next()) |name| {
                if (replacement.count == replacement.keys.len) return error.TooManyKeys;
                replacement.keys[replacement.count] = try parseKey(std.mem.trim(u8, name, " \t"));
                replacement.count += 1;
            }
        }
        result.bindings[index] = replacement;
    }
    var used: [512]bool = @splat(false);
    for (result.bindings) |value| {
        for (value.keys[0..value.count]) |key| {
            const index: usize = @intCast(@backingInt(key));
            if (used[index]) return error.DuplicateKey;
            used[index] = true;
        }
    }
    return result;
}

pub fn parseOrDefault(contents: []const u8) Keybinds {
    return parse(contents) catch .{};
}

pub fn load(allocator: std.mem.Allocator, io: std.Io) Keybinds {
    return loadFromDir(std.Io.Dir.cwd(), allocator, io);
}

fn loadFromDir(dir: std.Io.Dir, allocator: std.mem.Allocator, io: std.Io) Keybinds {
    const contents = dir.readFileAlloc(io, filename, allocator, .limited(16 * 1024)) catch |err| {
        if (err != error.FileNotFound) std.log.warn("Cannot read {s}: {s}; using default keybinds", .{ filename, @errorName(err) });
        return .{};
    };
    defer allocator.free(contents);
    const result = parse(contents) catch |err| {
        std.log.warn("Invalid {s}: {s}; using default keybinds", .{ filename, @errorName(err) });
        return .{};
    };
    std.log.info("Loaded keybinds from {s}", .{filename});
    return result;
}

test "partial overrides, aliases, comments, CRLF and disabling preserve other defaults" {
    const config = try parse("# custom\r\npause = p, tab # aliases\r\ntoggle_production = none\r\nzoom_in = +, KP_ADD\npan_up = i\nstep = none\n");
    try std.testing.expectEqual(Action.pause, config.actionFor(.P).?);
    try std.testing.expectEqual(Action.pause, config.actionFor(.TAB).?);
    try std.testing.expect(config.actionFor(.SPACE) == null);
    try std.testing.expectEqual(Action.pan_up, config.actionFor(.I).?);
    try std.testing.expectEqual(Action.zoom_in, config.actionFor(.EQUAL).?);
    try std.testing.expectEqual(Action.quit, config.actionFor(.ESCAPE).?);
    try std.testing.expect(config.actionFor(.RIGHT) == null);
    try std.testing.expectEqualStrings("None", config.primaryName(.step));
    var hints: [512]u8 = undefined;
    try std.testing.expect(std.mem.startsWith(u8, try config.formatHints(&hints), "P pause"));
    const digits = try parse("pause = 1\n");
    try std.testing.expectEqual(Action.pause, digits.actionFor(._1).?);
}

test "chat toggle has a configurable default, can be disabled and ignores repeat" {
    const defaults: Keybinds = .{};
    try std.testing.expectEqual(Action.toggle_chat, defaults.actionFor(.C).?);
    try std.testing.expect(!Action.toggle_chat.acceptsRepeat());
    const custom = try parse("toggle_chat = F4, TAB\n");
    try std.testing.expectEqual(Action.toggle_chat, custom.actionFor(.F4).?);
    try std.testing.expectEqual(Action.toggle_chat, custom.actionFor(.TAB).?);
    try std.testing.expect(custom.actionFor(.C) == null);
    var hints: [512]u8 = undefined;
    try std.testing.expect(std.mem.endsWith(u8, try custom.formatHints(&hints), "F4 chat | P production"));
    const disabled = try parse("toggle_chat = none\n");
    try std.testing.expect(disabled.actionFor(.C) == null);
    try std.testing.expectError(error.DuplicateKey, parse("toggle_chat = SPACE\n"));
}

test "production toggle defaults to P, supports aliases and disabling, and ignores repeat" {
    const defaults: Keybinds = .{};
    try std.testing.expectEqual(Action.toggle_production, defaults.actionFor(.P).?);
    try std.testing.expect(!Action.toggle_production.acceptsRepeat());
    const custom = try parse("toggle_production = F4, TAB\n");
    try std.testing.expectEqual(Action.toggle_production, custom.actionFor(.F4).?);
    try std.testing.expectEqual(Action.toggle_production, custom.actionFor(.TAB).?);
    try std.testing.expect(custom.actionFor(.P) == null);
    const disabled = try parse("toggle_production = none\n");
    try std.testing.expect(disabled.actionFor(.P) == null);
    try std.testing.expectError(error.DuplicateKey, parse("toggle_production = C\n"));
    try std.testing.expectError(error.DuplicateKey, parse("pause = P\n"));
    try std.testing.expectEqualDeep(defaults, parseOrDefault("toggle_production = NotAKey\n"));
}

test "malformed or ambiguous files fall back to the complete default set" {
    const invalid = [_][]const u8{
        "pause: P",                      "unknown = P", "pause = NotAKey", "pause =",        "pause = P,",
        "pause = P\npause = TAB",        "pause = W",   "pause = P,P",     "pause = CTRL+P", "pause = P,TAB,F1,F2,F3",
        "pause = P\nspeed_up = NotAKey",
    };
    for (invalid) |contents| {
        if (parse(contents)) |_| return error.TestExpectedError else |_| {}
        const fallback = parseOrDefault(contents);
        try std.testing.expectEqualDeep(@as(Keybinds, .{}), fallback);
    }
    try std.testing.expectEqualDeep(@as(Keybinds, .{}), try parse("\n# empty file\n"));
}

test "file loading uses defaults for missing and invalid files and owns parsed data" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try std.testing.expectEqualDeep(@as(Keybinds, .{}), loadFromDir(tmp.dir, std.testing.allocator, std.testing.io));
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = filename, .data = "pause = P\ntoggle_production = none\n" });
    const custom = loadFromDir(tmp.dir, std.testing.allocator, std.testing.io);
    try std.testing.expectEqual(Action.pause, custom.actionFor(.P).?);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = filename, .data = "pause = P\nbad = W\n" });
    try std.testing.expectEqualDeep(@as(Keybinds, .{}), loadFromDir(tmp.dir, std.testing.allocator, std.testing.io));
    try std.testing.expectEqual(Action.pause, custom.actionFor(.P).?);
}

test "shipped example exactly reproduces defaults" {
    const contents = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "keybinds.conf.example", std.testing.allocator, .limited(16 * 1024));
    defer std.testing.allocator.free(contents);
    try std.testing.expectEqualDeep(@as(Keybinds, .{}), try parse(contents));
}
