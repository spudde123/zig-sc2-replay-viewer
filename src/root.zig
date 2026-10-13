//! Display-independent viewer utilities.
pub const cli = @import("cli.zig");
pub const image = @import("image.zig");
pub const playback = @import("playback.zig");

test {
    _ = cli;
    _ = image;
    _ = playback;
    _ = @import("renderer.zig");
    _ = @import("replay_worker.zig");
    _ = @import("camera_pan.zig");
    _ = @import("keybinds.zig");
    _ = @import("minimap_drag.zig");
    _ = @import("minimap_mapping.zig");
    _ = @import("replay_data.zig");
    _ = @import("chat_view.zig");
    _ = @import("observation_data.zig");
    _ = @import("camera_projection.zig");
    _ = @import("order_view.zig");
    _ = @import("unit_overlay.zig");
}
