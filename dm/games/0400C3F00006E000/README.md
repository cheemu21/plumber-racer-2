# Mario Kart World (`0400C3F00006E000`)

A Switch 2 game, SDK 19.3.3 built for the Switch 2 (`Ounce`), NVN2 API 231.16. Nintendo EPD's engine (sead / agl / gsys), modules `main`, `subsdk0` and `sdk`. **Runs on an iPhone 18 Pro in LiveContainer**: a whole Grand Prix cup has finished there, with about 3.9 GB of footprint against the phone's 8,192 MiB limit. Nothing from the game is in this repository: you need your own dump. It also runs on a Mac with Apple silicon, at about 50 fps in a race on an M5 with 16 GB. The [install tutorial](../../../TUTORIAL.md) goes through every step for both.

## Required game version

Only this build is supported. The base game with **no update and no DLC**:

| | |
|---|---|
| Title ID | `0400C3F00006E000` |
| Version | 1.0.0 (`ResourceSizeTable.Product.100` in its RomFS) |
| `main` build ID | `9e244438c3d8ef1c703a6a85ef99c4f0` |
| `subsdk0` build ID | `d39a7a3d44530bb61b35690e5b0383d5` |
| `sdk` build ID | `90ebba182862b9ecdc21fcb87b999012` |

The patches are made for these exact modules, so another version will not work until the profile is brought up on it. The version number comes from the build IDs, which match the [kartnative](https://github.com/pahorema/kartnative) fork's 1.0.0 note: a dump has no control data to read it from.

## Build it

You need a Mac with the tools in the main [README](../../../README.md#how-to-play), about 50 GB free for the game files and the build, and your own dump. No keys are needed for a dump.

1. Lay the dump out like this (the folder name is yours):
   ```
   Mario Kart World/
     base/exefs/   main, main.npdm, sdk, subsdk0, rtld
     base/romfs/   the game's files
   ```
2. Build the IPA. The first build compiles 11,561 shaders, 20 to 30 minutes on an M5; later builds reuse them:
   ```bash
   python3 scripts/build_ipa_from_nsp.py "Mario Kart World" --platform ios --romfs separate
   ```
3. The IPA lands in that folder. The game files stay out of it, in `Mario Kart World/0400C3F00006E000_build/extract/v0/RomFS.img` (21.7 GB).

## Install it

Tested only on an iPhone 18 Pro (A20 Pro) in LiveContainer. The app needs the increased memory limit and extended virtual addressing ([`app.entitlements`](app.entitlements)).

1. Install the IPA in LiveContainer. Reinstalling later keeps the game's data.
2. In the Files app, open **On My iPhone → LiveContainer → Data → Application →** the game's folder **→ Documents**, and copy `RomFS.img` there. LiveContainer's app settings show which folder it is. Do not launch until the copy has finished.
3. Keep at least 5 GB free beyond that: the game's memory lives in a file while it runs, and below 4 GB free at launch it falls back to normal memory and runs out in a race.
4. The first launch builds its pipelines for about 30 s behind a progress screen.

## Controls

A touch layout for racing (`pad_style kartworld`): a floating steering stick, gas and brake pedals, drift (A + R), item (A + L), look back (X), rewind (D-pad down), the map (Y), and + / −. Sliding between gas, drift and item keeps A held. Charge jumps and tricks are on drift. Quick spins are gas and brake together. The camera (right stick) has no touch control; a connected controller is not tested. The kart controls show when the game loads a race (its RaceInfo and minimap layouts open: `pad_show_files`) and are hidden by a two-finger double tap in its menus (the launcher's **On-screen controls**, `DM_KART_PAD`: In races / Always). The game reads the touch screen 40 to 60 times a second but acts on no touch in its menus (measured on an iPhone 17 Pro, 2026-11-08: taps delivered as proper touch states changed nothing), so while the controls are hidden, gestures stand in for the buttons: a tap presses A, a swipe the D-pad in its direction, a long press B. Its main menu draws a whole world behind its panels (1,400 to 2,400 draws a frame, as a race) and every layout is preloaded at boot, so neither the draw count nor the files tell a menu from a race by themselves; the draw count only hides the controls at boot and on loading screens. `DM_KART_TOUCH=1` sends touches to the game's touch screen instead. A two-finger tap anywhere presses L and R together (the title screen's "Press L + R"); a two-finger double tap shows or hides the controls by hand. The phone's gyro drives the game's motion controls when no controller supplies one (turn them on in the game's settings; the launcher's **Tilt sensitivity**, `DM_MOTION_GAIN`, scales it), and a sharp forward flick of the phone presses L, the item button, and a backward flick down + L, the item thrown backwards, while the controls are shown (**Flick for an item**, `DM_FLICK_ITEM`; forward flicks measured at -4.7 to -6.5 rad/s about the picture's x axis, the threshold is 4.5).

## Status

| | |
|---|---|
| Grand Prix | A whole cup finished on the iPhone; other courses and modes (Free Roam, Knockout Tour, Battle) are not tested |
| Picture | Right in the races tested; large textures are softer than the game's (`tex_soft`) |
| Frame rate | Not settled: **60 fps is not stable.** A race holds 60 fps for about a minute, then falls to about 40 ([Open](#open)) |
| Online, local wireless, GameChat | Not available |
| Save data | Saved in the app's Documents |

## What it needs

| Setting | Where | Why |
|---|---|---|
| `app_pool 0x265100000`, `mem_reserve 0x348000000`, `mem_alias 0x118000000`, `mem_stack 0x10000000` | [`game.tsv`](game.tsv) | the Switch 2's 12 GB layout leaves a game 9809 MiB; the game sets a heap of what is free less 1540 MB, just over 8 GiB. Measured in the [kartnative](https://github.com/pahorema/kartnative) fork |
| `mem_map_limit on` | `game.tsv` | what the game maps in the alias region is its `NinVirtualAddressHeap`, whose free size is what the system reports free: without the limit the game never let its blocks go (kartnative: 2.4 GB mapped by a fourth race, 1.25 GB with the limit) |
| `sys_resource 0x4000000` | `game.tsv` | the NPDM declares 64 MB, so virtual address memory is on |
| `render_cond on` | `game.tsv` | agl wraps its clears in render conditions, as in Donkey Kong Bananza |
| `op_mode handheld` | `game.tsv` | the user plays it handheld at 60 fps, on the iPhone and on the Mac; handheld renders at 720p |
| `tex_release on` | `game.tsv` | the terrain caches are 8192x8192 arrays of 68 layers in sparse pools, streamed by the CPU: about 2.5 GB of tiles that otherwise sat in memory twice ([Memory](#memory)) |
| `mem_file on`, `tex_soft on` | `game.tsv` | together they keep a race under the iPhone's limit ([Memory](#memory)) |
| [`app.entitlements`](app.entitlements) | `build_ipa.sh` | the increased memory limit and extended virtual addressing: on the iPhone 18 Pro in LiveContainer the game has about 6 GB |

## Shaders

- [`pso_manifest.tsv`](pso_manifest.tsv): the Mac's device list (6,110 shaders, 4,238 render pipelines, 175 compute pipelines) of the title, the menus, a pre-race movie and Mario Bros. Circuit.
- From `Shader/*.Nin_Ounce_NVN2.bfsha.zs`, as Donkey Kong Bananza's.
- The game draws with task and mesh shaders (NVN2 stages 6 and 7, `nvnCommandBufferDrawMeshTasks`): they map to the host's slots 3 and 4 and draw through Metal's mesh pipelines (`nvn_mtl.m` `mesh_pso`, `mesh_encode`). Their pixel shaders read flat per-primitive inputs, which the mesh shader writes from its second, geometry-type program header (at the control section's +0x64; `dmsh_meshstage.py`).
- A pixel shader writing an integer target only from flat inputs or constants is built with integer outputs (`dmsh_build.py` `fs_uint`): one R8Uint mesh pipeline was refused without it.

## Terrain

The game stores its terrain tiles (260x260 R16 height, RG8 material, RGBA8 and R11G11B10F colour, 68x68 RGBA16; a `CPU_CACHED` pool) into reused slots before `nvnTextureInitialize` and never flushes them. On NVN2 the GPU reads what the CPU stored, so an uncompressed texture whose first use is a sample is taken from its storage (`tex_cpu_content`, from kartnative 313e90f9; `t_sampled_storage`). Before it the ground was flat and Peach Beach had no sea there.

## Movies

- The 2560x1440 course-intro movie is VP9, decoded by libvpx on the host with 4 threads (2 fell behind on an iPhone: stutter and sound cut-outs, from the nxnative-mkw port).
- The cup's pre-race movie is H.264 through the newer `Initialize…Decoder` with parameter sets and `Get…DecoderOutputBufferProperties` with a colour space (`hle_codec_video.c`); without them the game aborted on entering a cup.
- The movie's frames go into an sRGB texture and its linear twin over the same storage. They were two Metal textures, so the presented one stayed on the first frame: an sRGB / linear pair now shares one texture through a view (`nvn_mtl.m`, `tex_mtl_`). The same fixed the missing textures of the title's movies.

## Picture and frame rate on the iPhone

Two code patches of this build ([`patches.py`](patches.py), from the [nxnative-mkw](https://github.com/Thijs2004/nxnative-mkw) port of the same build), both settings on the launcher's screen:

- **Render scale** (`DM_RENDER_SCALE`, 0.5 to 1.0): the game's own dynamic-resolution scaler is opened at the host's factor, so every 3D view, viewport and derived pass follows by the game's design. The iPhone default is `render_scale_ios 0.80` in [`game.tsv`](game.tsv), that port's High preset for 12 GB phones (iPhone 17 Pro, Air); the UI stays at full size.
- **Frame rate** (`DM_FPS_LOCK`, 30 / 60 / the game decides): the game picks its present interval every frame from how late the last one was and flips between 1 and 2 when it cannot keep 60, stepping its simulation per interval. The lock writes the interval itself. Measured on the Mac with the lock at 30: a flat 30.0 fps, no interval flips. The default is the game's own choice.
- While a full-screen movie plays (a picture 1280 wide or more; the 640x360 clips the menus loop do not count) the lock is paused and comes back half a second after the last picture: with the lock the pre-race movie's sound cut out for about 10 ms every 0.74 s, each 32768-sample block arriving late ([Open](#open)).

## Memory

The limit on an iPhone 18 Pro in LiveContainer is 8,192 MiB (footprint plus `os_proc_available_memory`, in the log's `on-screen up to frame` lines). With `mem_file` and `tex_soft` a whole cup ran there at 3.9 GB. What the host does:

- Memory pools get their zero-copy Metal buffer on first GPU use (`pool_buf`): 2,765 of 5,230 pools never get one.
- `tex_soft` keeps large block-compressed textures without their finest level, gives back the pages only that level holds, and uploads packaged textures on the CPU while their pool has no buffer. The GPU's upload would give the pool one, and iOS wires a buffer's whole pool: wrapped pools fell from 3.7 GB to 851 MB on the iPhone. The game copies source textures into its terrain arrays, and those stay whole (`soft_harden`): with the copy skipped, the road was purple.
- Sparse tiles follow physical pages: a page mapped in two places or textures takes one tile, uploaded again only when the game writes the page (`nvn_dirty_since`); with `tex_release` and guest memory anonymous, the uploaded pages go back to the system (`nvn_dirty_release`, about 860 MB; with `mem_file` they are the file's and stay).
- `mem_file` puts guest memory in a shared mapping of a file. It froze the game on the iPhone when it first wired the 2.4 GB main pool; with CPU uploads that pool has no buffer, and the rest (about 870 MB, largest 232 MB) wires in milliseconds. A 7 MB pool took 16 s on a Mac short of memory: expect stalls if the phone itself runs short.

Releasing the packaged textures' guest copies (about 2 GB) gave magenta textures: new textures came about 0x200 bytes below kept, released ones whose ranges had been written. It is off (`PKG_RELEASE` in `nvn_mtl.m`).

## Open

- 60 fps on the iPhone. For the first 53-70 s a race holds 60 fps with GPU p50 8 ms and the CPU at 4.7 GHz, about 4.2 W. Then, at similar draw counts, either the GPU takes 21 ms (about 38 fps, CPU 4.4 GHz, 2.1 W) or the CPU falls to 2.1 GHz with the GPU at 8 ms (about 46 fps); it can return to 60 fps for a while. A cold phone slows at the same time. Ruled out: `DM_NVN_BARRIER=game`, `DM_NVN_TBDR=1` (no change in traffic, about 415 MB loaded and 455 MB stored a frame), `DM_RT=0`. `DM_QOS_MAP=1` was reported with missing textures.
- A margin in a race on courses other than Mario Bros. Circuit.
- `DM_PRESENT_INTERVAL=display` in `Documents/env.txt` was reported to hold 60 fps, not yet measured in a log. It ignores the game's interval 2, and the game steps its simulation per interval, so a race may run too fast in those stretches. Not a default until that is checked.
- Why the present interval lock makes the movie player's sound blocks arrive late is not known: the lock is paused during full-screen movies as a workaround (`hle_codec_video.c`, `loader.c`), and the 1280-pixel cutoff that tells a movie from a looping clip is this game's.
- Frame rate in a race on the Mac: about 50 fps. Frames take about 12 ms of submit and present and 11-19 ms of GPU, and after a late one the game sets present interval 2 for a frame (`main+0x3aa0a4`, about 1,260 times in a 4-minute run).
