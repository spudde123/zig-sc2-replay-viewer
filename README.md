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
rendering.

### Runtime dependencies (downloaded releases)

Zig and development packages are not needed to run a release binary. Install
these viewer graphics libraries and Mesa's EGL implementation if missing:

```sh
# Ubuntu / Debian
sudo apt install libx11-6 libxi6 libxcursor1 libgl1 libegl1 libegl-mesa0

# Fedora
sudo dnf install libX11 libXi libXcursor mesa-libGL mesa-libEGL
```

A working graphics driver and X11/XWayland session are also required. Systems
using proprietary drivers may need their vendor's EGL implementation instead
of Mesa. These packages do not install SC2 or all of SC2's own dependencies.

On Ubuntu / Debian x86-64, pass
`--egl /usr/lib/x86_64-linux-gnu/libEGL.so.1`; the default is Fedora's
`/usr/lib64/libEGL.so.1`.

The viewer assumes the headless Linux SC2 4.10 client and matching replays/game
data. Required map data must already be installed; Linux
SC2 cannot download maps automatically.

## Controls

| Key | Action |
| --- | --- |
| Space | Pause/resume |
| Up / Down (also `]` / `[`) | Faster/slower: 0.25x–16x |
| Right Arrow | Advance one simulation loop while paused |
| Hold WASD | Smooth camera pan; combine keys for diagonals |
| Mouse wheel / `+` / `-` | Zoom in/out (keypad `+` / `-` also work) |
| Click minimap | Move the camera |
| Escape / close window / Ctrl+C | Exit and clean up SC2 |

The upper-left HUD shows game time / duration as `mm:ss`, playback speed and
state, loop counts, and control hints. The window title stays static.
Time is derived from the displayed frame's loop count at 22.4 loops per second,
not wall-clock time. Minutes continue past 59 for long replays. `1x` playback
targets that same loop rate; actual speed depends on rendering performance.
The final frame stays visible at replay end.

The minimap shows player names anchored at their starting bases (or first owned
unit if no base is available). These white labels identify ownership without
assuming SC2's rendered color mapping, including in mirror matchups. Players
whose starting units are not visible have no marker. Placement is approximate
on padded/non-square minimaps; names use the HUD's ASCII bitmap font.

## Options

- `--player ID`: perspective (default: `0`, all-player observer view). Other IDs
  select a participant's perspective and vision.
- `--egl PATH`: override SC2's EGL library (default: `/usr/lib64/libEGL.so.1`).
- `--osmesa PATH`: use OSMesa instead of EGL for SC2 rendering.
- `--disable-fog`: forward SC2's startup fog flag. This is not a reliable RGB
  visibility switch; use `--player 0` to see both players.
- `--port PORT`: API port (default: 5000).
- `--width N --height N`: SC2 render resolution (default: 640×480).
- `--camera-distance N`: initial observer camera distance (default: 40, viewer
  range: 10–100). Smaller values zoom in; larger values zoom out. Works in probe
  mode too. Zoom remains available while paused, but not after the replay ends.
  Distances 20, 40, and 80 were verified to change the RGB view on Linux SC2 4.10.
- `--verbose-sc2`: show SC2's startup/rendering diagnostics.
- `--help`: list all options.

Changing perspective requires restarting the viewer. Seeking, automatic camera
following, audio, and a full replay HUD are not implemented. Minimap navigation
is approximate on padded/non-square minimaps.

## GitHub builds and releases

`.github/workflows/build.yml` builds and tests on pushes to `main`, and can also
be run manually from **Actions → Build and release → Run workflow**.

- Leave `release_tag` empty to produce a downloadable Actions artifact only.
- Enter a new tag such as `v0.1.0` to publish a GitHub Release with the archive
  and its SHA-256 checksum. The tag points to the selected workflow commit.
- Select `prerelease` for preview releases. Existing tags/releases are not
  overwritten; use a new version to publish another build.

CI pins Zig 0.17.0 and Ubuntu 22.04, targeting baseline x86-64 and glibc 2.35.
Archives contain the viewer, README, project license, and third-party license
notices—not SC2 or replay data.
Compatible OpenGL/X11 runtime libraries are still required. On Ubuntu, override
SC2's Fedora-specific EGL default with
`--egl /usr/lib/x86_64-linux-gnu/libEGL.so.1`.

The zig-sc2 submodule commit must be pushed to its remote before publishing the
parent repository; CI checks out that exact commit recursively. No custom
release secret is needed: the release job uses GitHub's built-in token with
`contents: write` permission.

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

## License

The viewer's original code is [MIT licensed](LICENSE). Dependencies retain their
own licenses: zig-sc2 ([MIT](lib/zig-sc2/LICENSE)), Sokol/sokol-zig
([zlib](licenses/sokol.txt)), and Zig's standard library/runtime
([MIT](licenses/zig.txt)). Release archives include these notices in `licenses/`
alongside the project's `LICENSE`.
