# zig-sc2-replay-watcher

A Zig 0.17 Linux replay viewer. Headless SC2 renders the game and minimap through
EGL or OSMesa; Sokol displays those images in an OpenGL window. Playback uses
explicit stepping, not realtime mode.

## Build and run

```sh
git submodule update --init --recursive
zig build
zig build run -- \
  --sc2 /path/to/StarCraftII \
  --replay /path/to/replay.SC2Replay \
  --player 0
```

Alternatively, run `zig-out/bin/zig_sc2_replay_watcher` with the same arguments.
`--sc2` is the installation root containing `Versions/` and `SC2Data/`. Relative
replay paths are resolved before launching SC2.

On Fedora, build dependencies are typically provided by:

```sh
sudo dnf install libX11-devel libXi-devel libXcursor-devel mesa-libGL-devel alsa-lib-devel
```

The viewer uses X11/GLX; XWayland works on Wayland desktops. SC2 additionally
needs a compatible EGL implementation, or an OSMesa library for software
rendering. OSMesa support is untested.

Replays require their exact SC2 base build/data version and map/cache data. The
viewer reads replay metadata, then relaunches the matching installed binary
with `-dataVersion`. Linux SC2 cannot download missing versions or maps
automatically.

## Controls

| Key | Action |
| --- | --- |
| Space | Pause/resume |
| Up / Down (also `]` / `[`) | Faster/slower: 0.25x–16x |
| Right Arrow | Advance one simulation loop while paused |
| WASD | Pan the camera |
| Click minimap | Move the camera |
| Escape / close window / Ctrl+C | Exit and clean up SC2 |

The upper-left HUD shows game time / duration as `mm:ss`, playback speed and
state, loop counts, and control hints. The window title stays static.
Time is derived from the displayed frame's loop count at 22.4 loops per second,
not wall-clock time. Minutes continue past 59 for long replays. `1x` playback
targets that same loop rate; actual speed depends on rendering performance.
The final frame stays visible at replay end.

## Options

- `--player ID`: perspective (default: `0`, all-player observer view). Other IDs
  select a participant's perspective and vision.
- `--egl PATH`: override SC2's EGL library (default: `/usr/lib64/libEGL.so.1`).
- `--osmesa PATH`: use OSMesa instead of EGL for SC2 rendering.
- `--disable-fog`: forward SC2's startup fog flag. This is not a reliable RGB
  visibility switch; use `--player 0` to see both players.
- `--port PORT`: API port (default: 5000).
- `--width N --height N`: SC2 render resolution (default: 640×480).
- `--verbose-sc2`: show SC2's startup/rendering diagnostics.
- `--help`: list all options.

Changing perspective requires restarting the viewer. Seeking, automatic camera
following, audio, and a full replay HUD are not implemented. Minimap navigation
is approximate on padded/non-square minimaps.

## Tests and diagnostics

```sh
zig build test                       # no SC2/display required
zig build -Doptimize=ReleaseSafe

# Render through SC2 without opening the viewer; optionally save its image:
zig build run -- \
  --sc2 /path/to/StarCraftII \
  --replay /path/to/replay.SC2Replay \
  --player 0 --probe --probe-loops 64 --capture /tmp/sc2-frame.ppm
```

`--quit-after SECONDS` automatically exits the GUI for smoke testing. Captures
save SC2's main image, not the viewer's HUD or minimap layout.

## Structure

- `lib/zig-sc2`: submodule containing the protocol/client and `ReplaySession`
  process/version lifecycle. Replay operations are `observe()`, `advance()`,
  and `close()`; the existing bot runner retains its defaults.
- `src/replay_worker.zig`: owns SC2 I/O on a worker, playback timing, and a
  bounded frame mailbox. Image bytes are copied before response memory resets.
- `src/renderer.zig`: owns Sokol textures, the minimap, and the playback HUD
  on the GUI thread.
- `src/cli.zig`, `src/playback.zig`, `src/image.zig`: argument parsing, stepping
  and time formatting, and image conversion/ownership.
