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
sudo apt install libx11-6 libxi6 libxcursor1 libgl1 libegl1 libegl-mesa0 libbz2-1.0

# Fedora
sudo dnf install libX11 libXi libXcursor mesa-libGL mesa-libEGL bzip2-libs
```

The player-stat reader dynamically loads the system `libbz2` runtime to decompress
replay tracker data. No bzip2 development headers, external command or Python
are required. On Arch, install `bzip2`. Without a usable library, statistics are
marked unavailable and replay playback continues normally.

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
| C | Show/hide chat |
| P | Show/hide the production/units/structures panel |
| 1 / 2 / 3 | Production + research / units / structures tabs |
| Hold WASD | Smooth camera pan; combine keys for diagonals |
| Mouse wheel / `+` / `-` | Zoom in/out (keypad `+` / `-` also work) |
| Click / hold and drag minimap | Move the camera; zoom is preserved |
| Click a unit in the game image | Select it and show orders / target arrows |
| Right-click / click empty game space | Clear unit selection |
| Escape / close window / Ctrl+C | Exit and clean up SC2 |

### Custom keybinds

At startup, the viewer optionally reads `keybinds.conf` from the **working
directory** (where you launch it, not necessarily where the executable lives).
Copy `keybinds.conf.example` to `keybinds.conf`, or create a file with only the
controls you want to change:

```ini
# Replace WASD with IJKL and pause with P.
pause = P
pan_up = I
pan_left = J
pan_down = K
pan_right = L
```

Each `action = key, key` line replaces that action's bindings; omitted actions
retain their defaults. Available actions are `pause`, `speed_up`, `speed_down`,
`step`, `zoom_in`, `zoom_out`, `quit`, `toggle_chat`, `toggle_production`,
`tab_production`, `tab_units`, `tab_structures`, `pan_up`, `pan_left`,
`pan_down`, and `pan_right`. Use `none` to unbind an action. Up to four keys per action are
supported; names are case-insensitive and `#` starts a comment.

Key names follow Sokol's keycodes: letters, digits, `SPACE`, `ESCAPE`, `ENTER`,
`TAB`, `UP`, `DOWN`, `LEFT`, `RIGHT`, `F1`–`F25`, `PAGE_UP`, `PAGE_DOWN`,
`LEFT_BRACKET`, `RIGHT_BRACKET`, `EQUAL`, `MINUS`, `KP_ADD`, `KP_SUBTRACT`, etc.
`+`/`=` alias `EQUAL`, `-` aliases `MINUS`, and `[`/`]` alias the bracket keys.
These are keycodes, not typed characters; keyboard-layout differences may apply.
Modifier combinations such as `Ctrl+P` are not supported. Mouse-wheel zoom and
left-click minimap navigation remain fixed. Hold the left button and drag to
follow the pointer; dragging outside the minimap clamps to its edges. Releasing
the button, leaving the window, or losing focus stops dragging. Minimap dragging
takes priority over held keyboard pan keys.

If the file is missing, defaults are used silently. An unreadable or invalid file
(including unknown names, duplicate actions, conflicting keys after merging with
defaults, or files exceeding the 16 KiB read limit) falls back to **all defaults**
with a warning. To move a key to another action, also rebind or disable its old
action. Changes take effect after restarting; `--help` lists the defaults.

The upper-left HUD shows game time / duration as `mm:ss`, playback speed and
state, and loop counts. Keybind hints are not displayed. The window title stays static.
Time is derived from the displayed frame's loop count at 22.4 loops per second,
not wall-clock time. Minutes continue past 59 for long replays. `1x` playback
targets that same loop rate; actual speed depends on SC2 and frame-production
performance. Advancement batches are capped at 16 loops to favor more frequent
image updates over large catch-up jumps. In busy scenes, the requested speed
may not be reached; excess catch-up debt is discarded rather than accumulated.
The final frame stays visible at replay end.

The viewer accepts exactly two non-observer participants, checked using SC2's
replay metadata before starting the replay. Other participant counts cause an
error and clean shutdown, independently of whether optional stats parsing works.
Actual player IDs are preserved and mapped to two internal slots, rather than
used as zero-based array indices; IDs need not be contiguous. Observer and neutral owner IDs are not participant slots.

The minimap shows player names anchored at their starting bases (or first owned
unit if no base is available). These white labels identify ownership without
assuming SC2's rendered color mapping, including in mirror matchups. Players
whose starting units are not visible have no marker. Labels and navigation use
the playable-area crop and aspect-ratio padding of SC2's square minimap; names
use the HUD's ASCII bitmap font.

Camera movement stops 12 world units inside the reported playable rectangle,
using the same bounds for keyboard pan, minimap navigation and zoom requests.
This conservative margin avoids silent engine camera clamping near map edges;
projection uses the constrained coordinates actually sent to SC2. On unusually
small maps, an axis narrower than 24 units is fixed at its centre. Custom camera
bounds can differ from playable bounds, so this is not an exact engine-derived
limit for every map.

## Chat

A bottom-right panel shows replay chat with player names and game times.
Press **C** or click **Hide chat / Show chat** below the panel to toggle its
visibility (hidden initially). A newly received message automatically opens the
panel if it is hidden; after manually hiding it, it stays hidden until another
new message arrives. Existing history alone does not reopen it. Rebind the toggle
with `toggle_chat = F4` in `keybinds.conf`. Hiding it does not stop message
collection or clear recent history.
The button also works while loading, paused, and at replay end; visibility is
local to the GUI and resets when the viewer restarts.
Messages stay visible while paused and at replay end. Unknown names fall back to
`Player N` (or `Unknown` if the sender ID is missing). Times use the observation
that delivered the message; SC2 does not provide exact chat event timestamps.

The panel wraps text, showing the newest 12 lines and at most three lines per
message; longer text ends in `...`. Recent history and the worker's independent
chat queue each hold 128 messages. Overflow retains the newest messages and marks
its header `Chat *`. Message text is copied before SC2 response memory resets,
bounded to 512 bytes, and is not lost when newer images replace pending frames.
The existing bitmap renderer replaces unsupported Unicode characters with `?`.
There is no scrollback control yet. Very small windows hide the panel rather than
covering the minimap.

## Player resources

A separate top-right panel shows sampled minerals (`M`) and vespene (`V`),
followed by `A: army supply W: worker supply S: used / cap` for each player,
independently of observer `PlayerCommon` data. Worker supply is the recorded
regular-worker count (each costs one supply). Army supply is derived from the
same sample as `max(0, used supply - worker count)`: it includes reserved
production supply, including workers in training, rather than representing
only completed army units.
It hides when there is too little space to avoid overlapping the other panels.
A small native parser reads only `SPlayerStatsEvent` from the replay's tracker
stream, targeting base build **75689** and its MPQ v3 single-unit files.
Only uncompressed or bzip2-compressed tracker data is supported.

Samples normally occur every 160 loops (about 7.14 seconds at Faster speed).
The viewer uses the latest sample at or before the displayed image's loop.
Values can therefore lag gameplay by roughly seven seconds between samples;
no sample age is displayed. Values come from **recorded samples, not live unit
counts or interpolated balances**; the army estimate is derived from those samples. Fractional supply is preserved, and recorded food-made is clamped
to the standard melee cap of 200. Before the first sample, values are pending.
Missing tracker data, other builds/formats, or missing `libbz2` disable stats
without preventing replay playback.

Resources remain visible when production is collapsed with **P**. Pausing
freezes the displayed values. Parsing happens once on the worker; each published frame
owns its selected values, with no GUI references into parser storage.

## Production, units and structures

The top-left panel keeps game time, speed/state and loop counts above tabs titled
**1P+R 2U 3S**. Press **1**, **2**, or **3** (or click their titles) for
production + research, units, or structures. Selecting a tab opens the panel;
the active title is highlighted. Its **Hide / Show** button and **P** collapse
the selected view without hiding playback information. Tab selection is retained
while collapsed. Rebind with `tab_production`, `tab_units`, `tab_structures`
and `toggle_production`. Controls ignore key repeats and also work while loading,
paused and after replay end.

Units and structures are grouped by owner and unit type, with rows such as
`Marine: R:55 B:2`. `R` counts completed, visible reported units;
`B` reuses the production view's active entries (not zero-progress queued jobs).
Ready counts are soft green, building counts amber, and zero counts muted gray;
unit names remain off-white and the labels retain the distinction without color.
Structure classification comes from SC2's unit-type attributes and is copied
into each snapshot. Reported bunker/transport passengers are counted as ready
units, attributed to their carrier's owner, and deduplicated by tag against
top-level units and other passenger records. Counts do not infer hidden or
unreported units. Modes with distinct unit type IDs have distinct rows.

In the production + research tab, each player has a separate section. Unfinished units/structures, active training
and production morphs use green progress bars; research uses purple bars and an
`R:` label. Identical results share a row with up to three short bars (furthest
along first), followed by `N more` for additional active entries. Zero-progress
queued orders and completed jobs are excluded. Worker build commands do not
count again beside their unfinished structures; eggs/cocoons and ongoing morphs
are represented by their resulting unit when known.

Training and upgrade names come from matching SC2 game data, with known ability
names as fallbacks rather than guessed results. The panel uses the same owned
observation as the displayed image, so pausing freezes it and completed,
cancelled or destroyed entries disappear on the next observation. Missing
production information for a perspective is not inferred.

Panel height is bounded above the minimap/chat. Limited space is shared between
players, prioritizing research, with per-player overflow summaries. Very small
windows hide production rather than overlap other controls. Panel clicks and
wheel events do not select units or zoom the camera underneath it.

## Unit orders

Click a visible unit to highlight its projected footprint and show a text box
with its unit type, tag, owner and first reported order. Only that order's target
is drawn, using a yellow arrow. Additional orders are retained in the snapshot
but shown only as a count, not extra text or arrows. Training/targetless orders show text and
progress but no arrow. Missing or hidden targets are marked unavailable rather
than drawing toward stale positions. “No orders reported” does not prove the
unit is idle; the API may omit orders for a perspective.

The details box includes green HP, blue shield, and purple energy bars with
current/max values when a positive maximum is reported. Empty applicable bars
remain visible. Positive mineral/vespene contents are shown as integers, and
units with `ideal_harvesters > 0` show `Harvesters: assigned / ideal`.
If any upgrade level is nonzero, `Upg: attack/armor` is shown, with a third shield
level for shield-bearing units (or when a shield upgrade is reported). All-zero
upgrade levels are omitted. These values update with the displayed observation, including while paused after a
camera refresh.

Selection follows the unit tag across frames, pan and zoom. Right-click or click
empty game space to clear it; losing the unit/vision also clears selection.
Selection works while paused and at replay end, and never sends game commands.
HUD/chat/minimap controls take priority over game-image picking. The order box
tries to stay near its unit without covering UI panels; it hides on cramped
windows or when its unit is offscreen.

Images, camera commands, units and orders cross the worker/GUI boundary as one
owned snapshot, including production progress and copied product names; chat
remains an independent event FIFO. Projection never reads
the worker's ahead-of-image camera request state.

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
- `--projection-markers`: draw projected raw unit anchors for camera validation
  (off by default, up to 4096 onscreen markers).
- `--verbose-sc2`: show SC2's startup/rendering diagnostics.
- `--help`: list all options.

Changing perspective requires restarting the viewer. Seeking, automatic camera
following, audio, and a full replay HUD are not implemented. SC2 can silently
clamp camera requests near map edges.

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
save SC2's main image, not the viewer's HUD, chat, unit overlays, or minimap layout.

## Structure

Entry points (`main.zig`, `root.zig`) and CLI parsing remain at the `src/` root.
Files are grouped by responsibility:

- `src/replay/`: SC2 I/O, playback timing, owned observations/images, player
  metadata, the production ability catalog and the narrow replay-stat reader.
- `src/input/`: keybindings, held-key camera panning and minimap drag state.
- `src/camera/`: world/image projection and minimap coordinate transforms.
- `src/ui/`: presentation-only formatting/layout and Sokol rendering.

- `lib/zig-sc2`: submodule containing the protocol/client and `ReplaySession`
  process/version lifecycle. Replay operations are `observe()`, `advance()`,
  and `close()`; the existing bot runner retains its defaults.
- `src/replay/replay_worker.zig`: owns SC2 I/O, playback timing, a latest-frame mailbox,
  and a separate FIFO chat queue. Chat is collected from every observation,
  including initialization and camera-only observations.
- `src/replay/replay_data.zig`: value-owned player/chat data and frame-aligned unit/order
  scenes, independent of protocol and rendering types. Scenes use sorted units
  and flattened order arrays; chat uses bounded event queues.
- `src/replay/observation_data.zig`: copies borrowed raw observations, samples terrain,
  and attaches the camera command matching the image.
- `src/camera/camera_projection.zig`: empirical 3D projection, exact letterboxing,
  screen-space picking and line clipping.
- `src/replay/player_stats.zig`: extracts the build-75689 stat timeline from MPQ;
  uses dynamically loaded native libbz2 and skips unrelated tracker events.
- `src/ui/player_stats_view.zig`: bounded player-resource formatting.
- `src/ui/chat_view.zig`, `src/ui/order_view.zig`, `src/ui/production_view.zig`,
  `src/ui/inventory_view.zig`: bounded formatting and grouped production/inventory layouts.
- `src/ui/unit_overlay.zig`: GUI-thread selection footprint, arrows and order box.
- `src/ui/renderer.zig`: owns Sokol textures and composes the world image/overlays,
  minimap, playback HUD, production/research and chat. GUI state holds the selected tag and recent
  chat history; it never retains SC2 response pointers.
- `src/cli.zig`, `src/replay/playback.zig`, `src/replay/image.zig`: argument parsing, stepping
  and time formatting, and image conversion/ownership.

## License

The viewer's original code is [MIT licensed](LICENSE). Dependencies retain their
own licenses: zig-sc2 ([MIT](lib/zig-sc2/LICENSE)), Sokol/sokol-zig
([zlib](licenses/sokol.txt)), and Zig's standard library/runtime
([MIT](licenses/zig.txt)). Release archives include these notices in `licenses/`
alongside the project's `LICENSE`. Replay-format/algorithm references are
mpyq (BSD-2-Clause) and Blizzard s2protocol (MIT); their notices are included as
`licenses/mpyq.txt` and `licenses/s2protocol.txt`.
