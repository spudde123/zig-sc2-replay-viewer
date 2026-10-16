# zig-sc2-replay-watcher

A Linux SC2 replay viewer built with Zig 0.17. SC2 renders the game and minimap;
the viewer adds playback controls, chat, player resources, production, unit and
structure counts, and selected-unit details.

## Requirements

- Headless Linux **SC2 4.10 / build 75689**, with matching replay and game data.
- Replays with **exactly two non-observer participants**.
- Required map data already installed: Linux SC2 cannot download maps automatically.
- A working graphics driver and an X11 or XWayland session.

SC2 uses EGL for rendering, or OSMesa for software rendering. Proprietary drivers
may require their vendor's EGL implementation rather than Mesa.

## Build and run

Install **Zig 0.17.0** and build (Zig fetches the pinned dependencies automatically):

```sh
zig build -Doptimize=safe
zig build run -Doptimize=safe -- \
  --sc2 /path/to/StarCraftII \
  --replay /path/to/replay.SC2Replay
```

Zig 0.17 names the optimization modes `debug` (the default), `safe`, `fast`,
and `small`. Use `safe` for optimized builds with runtime safety checks.

Alternatively, run `zig-out/bin/zig_sc2_replay_watcher` with the same arguments.
`--sc2` is the installation root containing `Versions/` and `SC2Data/`.

On Fedora, install build dependencies with:

```sh
sudo dnf install libX11-devel libXi-devel libXcursor-devel mesa-libGL-devel alsa-lib-devel
```

### Running a release binary

Release binaries do not require Zig or development packages. Install missing
runtime libraries:

```sh
# Ubuntu / Debian
sudo apt install libx11-6 libxi6 libxcursor1 libgl1 libegl1 libegl-mesa0 libbz2-1.0

# Fedora
sudo dnf install libX11 libXi libXcursor mesa-libGL mesa-libEGL bzip2-libs
```

These packages do not install SC2 or all of its dependencies. The `libbz2` runtime
is used for replay statistics; on Arch, install `bzip2`. No Python or external
bzip2 command is needed. If statistics cannot be read, playback continues.

On Ubuntu / Debian x86-64, add:

```sh
--egl /usr/lib/x86_64-linux-gnu/libEGL.so.1
```

The default EGL path is Fedora's `/usr/lib64/libEGL.so.1`.

## Controls

| Control | Action |
| --- | --- |
| Space | Pause/resume |
| Up / Down, or `]` / `[` | Faster/slower: 0.25x–16x |
| Right Arrow | Advance one simulation loop while paused |
| 1 / 2 / 3 | Production + research / units / structures tabs |
| P | Show/hide the selected tab's panel |
| C | Show/hide chat |
| Hold WASD | Pan the camera; diagonals supported |
| Mouse wheel / `+` / `-` | Zoom; keypad `+` / `-` also work |
| Click or drag minimap | Move the camera, preserving zoom |
| Click a unit | Show details and its first reported order/target |
| Right-click / click empty space | Clear selection |
| Escape / close window / Ctrl+C | Exit and clean up SC2 |

Requested playback speeds are targets: busy scenes may run slower. The HUD shows
game time, duration, speed/state and loop counts. SC2 closes when the replay ends;
the final frame, unit data, statistics and chat remain available in the viewer.

### Custom keybinds

Copy `keybinds.conf.example` to `keybinds.conf` in the **directory you launch
from**, or create a file containing only the overrides you need:

```ini
pause = TAB
pan_up = I
pan_left = J
pan_down = K
pan_right = L
```

Each line replaces one action's bindings; omitted actions retain their defaults.
Use comma-separated keys for aliases, `none` to disable an action, and `#` for
comments. Names are case-insensitive. Modifier combinations such as `Ctrl+P`
are not supported; mouse controls are fixed.

Keys cannot be shared between actions. When moving a key, also rebind or disable
its original action. Invalid configuration restores **all defaults** with a
warning. Changes take effect after restarting.

## Panels and unit details

### Production, units and structures

The top-left panel has tabs **1P+R 2U 3S**, selectable by number keys or clicking
the titles. Selecting a tab opens the panel; **P** or **Hide / Show** collapses it.

- **Production + research:** construction, active training, morphs and research,
  grouped per player/result with progress bars. Building upgrades with no reported
  progress use a muted `?` bar rather than an estimated percentage.
  Zero-progress queued jobs are excluded.
- **Units / structures:** grouped per player/type, for example
  `Marine: R:55 B:2`. **R** means ready; **B** means in progress. Ready counts
  are green, building counts amber, and zeros muted gray. Reported passengers
  inside bunkers and transports are included without double-counting.

Lists grow toward the minimap, share space between players, and show overflow
counts when space runs out. Counts reflect reported units, not hidden units
inferred from earlier observations.

### Player resources

The top-right panel shows each player's minerals, vespene, workers and supply:

```text
M: 125  V: 50
W: 60 S: 84 / 92
```

These are **recorded replay samples**, normally every 160 loops—about
**7.14 seconds at Faster speed**. The viewer uses the latest sample at or before
the displayed frame, without interpolation, so values may lag gameplay by
roughly seven seconds. Workers are the regular-worker count; total used supply
includes supply reserved for production. Fractional supply is preserved, and
the supply cap is limited to 200.

Values are pending before the first sample. Unsupported or missing tracker data,
or an unavailable `libbz2` runtime, shows **Unavailable** without stopping playback.

### Chat

Chat starts hidden and **opens automatically when a new message arrives**.
After hiding it, existing history alone does not reopen it. **C** or the
**Hide chat / Show chat** button toggles visibility without clearing history.

Messages show gray timestamps, blue sender names and white text, with spacing
between messages. Long messages wrap and may be shortened with `...`. Only
recent history is shown; there is no scrollback yet. Unsupported Unicode is
replaced with `?`.

### Selected units

Click a visible unit for its name, owner, HP/shields/energy, resource or harvester
information where applicable, and upgrade levels such as `Upg: 2/1/3`.
All-zero upgrade levels are hidden.

Only the first reported order and its target arrow are shown; additional orders
appear as a count. Missing or hidden targets are not drawn. Selection follows
the unit until it disappears or becomes hidden.

Panels and details update with the displayed observation and remain usable while
paused. Small windows may hide panels rather than overlap other controls.

## Options and limitations

Run `zig_sc2_replay_watcher --help` for all options. Common options:

- `--player ID`: perspective; default **0** shows both players. Other IDs select
  a participant's perspective. Changing perspective requires restarting.
- `--egl PATH` / `--osmesa PATH`: select SC2's rendering library.
- `--width N --height N`: render resolution; default 640×480.
- `--camera-distance N`: initial zoom distance; default 40, range 10–100.
- `--port PORT`: API port; default 5000.
- `--verbose-sc2`: show SC2's startup/rendering diagnostics.

Use `--player 0` for the all-player view; `--disable-fog` is not a reliable RGB
visibility switch. Camera movement is restricted near map edges. Seeking,
automatic camera following and audio are not implemented.

## Tests and diagnostics

```sh
zig build test  # no SC2 or display required

# Check SC2 rendering without opening the viewer:
zig build run -- \
  --sc2 /path/to/StarCraftII \
  --replay /path/to/replay.SC2Replay \
  --probe --probe-loops 64 --capture /tmp/sc2-frame.ppm
```

`--quit-after SECONDS` closes the GUI automatically for smoke testing. Captures
save SC2's image, not the viewer's panels or overlays.

## License

The viewer is [MIT licensed](LICENSE). Dependencies retain their own licenses:
zig-sc2 ([MIT](https://github.com/spudde123/zig-sc2/blob/master/LICENSE)), Sokol/sokol-zig
([zlib](licenses/sokol.txt)), and Zig's standard library/runtime
([MIT](licenses/zig.txt)). Replay-format references are mpyq
([BSD-2-Clause](licenses/mpyq.txt)) and Blizzard s2protocol
([MIT](licenses/s2protocol.txt)). Release archives include the project license
and third-party notices, but not SC2 or replay data.
