//! Display-independent viewer utilities.
pub const cli = @import("cli.zig");
pub const image = @import("replay/image.zig");
pub const playback = @import("replay/playback.zig");

test {
    _ = cli;
    _ = image;
    _ = playback;
    _ = @import("ui/renderer.zig");
    _ = @import("replay/replay_worker.zig");
    _ = @import("input/camera_pan.zig");
    _ = @import("input/keybinds.zig");
    _ = @import("input/minimap_drag.zig");
    _ = @import("camera/minimap_mapping.zig");
    _ = @import("replay/replay_data.zig");
    _ = @import("ui/chat_view.zig");
    _ = @import("replay/observation_data.zig");
    _ = @import("camera/camera_projection.zig");
    _ = @import("ui/order_view.zig");
    _ = @import("replay/production_catalog.zig");
    _ = @import("replay/player_stats.zig");
    _ = @import("ui/player_stats_view.zig");
    _ = @import("ui/production_view.zig");
    _ = @import("ui/unit_overlay.zig");
}
