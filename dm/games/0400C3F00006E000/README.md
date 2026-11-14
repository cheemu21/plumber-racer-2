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

A touch layout for racing (`pad_style kartworld`): a floating steering stick, gas and brake pedals, drift (A + R), item (A + L), look back (X), rewind (D-pad down), the map (Y), and + / −. Sliding between gas, drift and item keeps A held. Charge jumps and tricks are on drift. Quick spins are gas and brake together. The camera (right stick) has no touch control; a connected controller is not tested.

## Status

| | |
|---|---|
| Grand Prix | A whole cup finished on the iPhone; other courses and modes (Free Roam, Knockout Tour, Battle) are not tested |
| Picture | Right in the races tested; large textures are softer than the game's (`tex_soft`) |
| Frame rate | Not settled: **60 fps is not stable.** A race holds 60 fps for about a minute, then can fall to about 40 ([Open](#open)). The launcher caps it at 30, 40, 45 or 60 fps and has three graphics presets ([Frame rate](#frame-rate)): checked on the Mac, not yet on the iPhone |
| Online, local wireless, GameChat | Not available |
| Save data | Saved in the app's Documents |

## What it needs

| Setting | Where | Why |
|---|---|---|
| `app_pool 0x265100000`, `mem_reserve 0x348000000`, `mem_alias 0x118000000`, `mem_stack 0x10000000` | [`game.tsv`](game.tsv) | the Switch 2's 12 GB layout leaves a game 9809 MiB; the game sets a heap of what is free less 1540 MB, just over 8 GiB. Measured in the [kartnative](https://github.com/pahorema/kartnative) fork |
| `mem_map_limit on` | `game.tsv` | what the game maps in the alias region is its `NinVirtualAddressHeap`, whose free size is what the system reports free: without the limit the game never let its blocks go (kartnative: 2.4 GB mapped by a fourth race, 1.25 GB with the limit) |
| `sys_resource 0x4000000` | `game.tsv` | the NPDM declares 64 MB, so virtual address memory is on |
| `render_cond on` | `game.tsv` | agl wraps its clears in render conditions, as in Donkey Kong Bananza |
| `op_mode handheld` | `game.tsv` | the user plays it handheld at 60 fps, on the iPhone and on the Mac; handheld renders at 1920x1080, docked at 2560x1440 |
| `present_interval display`, `frame_caps on`, `render_presets` | `game.tsv` | one frame per display tick at the chosen cap, with the presets in the launcher ([Frame rate](#frame-rate)) |
| [`patches.py`](patches.py) | rewriter | the render scale and the frame loop's frame time ([Frame rate](#frame-rate)); the screen shape ([Screen shape](#screen-shape)) |
| `gpu_timestamps segment` | `game.tsv` | the game's own dynamic resolution reads the GPU's time from its timestamp reports ([Frame rate](#frame-rate)) |
| `tex_release on` | `game.tsv` | the terrain caches are 8192x8192 arrays of 68 layers in sparse pools, streamed by the CPU: about 2.5 GB of tiles that otherwise sat in memory twice ([Memory](#memory)) |
| `mem_file on`, `tex_soft on` | `game.tsv` | together they keep a race under the iPhone's limit ([Memory](#memory)) |
| [`app.entitlements`](app.entitlements) | `build_ipa.sh` | the increased memory limit and extended virtual addressing: on the iPhone 18 Pro in LiveContainer the game has about 6 GB |

## Frame rate

The launcher's **Graphics preset** and **Frame rate cap** (current).

**Render scale.** `main+0xc0ff60` builds the game's resolution table from `game__GamePerformanceGraphicsConfig`, whose `Resolution…For3D` entries size the scene apart from the `Resolution…Screen` ones (`main+0x1c6cad4` names them). The stub in `patches.py` scales the six 3D entries once, after the table is filled. The presets are Ultra Potato 25 %, Potato 50 %, Default 75 % and High 100 %: 480x270, 960x540, 1440x810 and 1920x1080 in handheld. Ultra Potato is not tested on any device. On the Mac at 50 %, in a race on Mario Bros. Circuit: the 3D passes are 960x540, the final picture stays 1920x1080 and the HUD stays sharp. Docked at 50 % was not reached in a race on the Mac: scripted input did not get past the title there.

**Dynamic resolution.** agl's dynamic resolution times the GPU as the difference of timestamp reports in one submission, as in Donkey Kong Bananza. With one time for the whole submission (the host's default) the difference reads about 0, so the scene never stepped down however long the GPU took: on an iPhone that cools down, the GPU slowing to 21 ms a frame meant about 38 fps at full size. `gpu_timestamps segment` gives each report its segment's GPU start or end, less the GPU's idle gaps between segments while the host translates the next one (`seg_gap_before`, from nxnative #1350; without it the size swung from frame to frame and distant mountains flickered on an M5). On a 16 GB M1 Pro upstream measured the first race's scene stepping down from 2048x1152 to 1328x748 and the race going from 33.5 to 42.2 fps (nxnative #1229). It steps down from the render scale's sizes, so the presets set the most it renders. `DM_NVN_GPU_TS=submission` gives the old fixed size. On the Mac (2026-11-09, 19.5:9, 75 %) a race held 60 fps (frame p50 16.6-16.9 ms) with it as without it, so the GPU stayed in budget there and nothing stepped down; the step-down itself is not yet seen on the iPhone.

**Game speed.** `sead::GameFrameworkOunce`'s frame (`main+0x3a9e28`) steps game time by the present interval it picks, 1 or 2 sixtieths of a second, from a running sum of the frame's time less the interval's. The time it read (`+0x128`) stops before the wait for the present, so frames that only waited were not counted and the game ran slow: 0.5 of real time at a 30 fps cap. On an iPhone at 45 fps in the host's own drop it stepped 2 only about 50 times in 300 frames, about 0.87 of real time assuming single-frame steps. It now reads the whole frame (`+0xe8`). The mean step in a race on the Mac, windowless, against what real time needs:

| Cap | Frame | Step measured | Step needed |
|---|---|---|---|
| 60 | 17 ms | 1.00 | 1.00 |
| 45 | 22 ms | 1.33 | 1.33 |
| 40 | 25 ms | 1.50 | 1.50 |
| 30 | 33 ms | 2.00 | 2.00 |

The steps are 1 or 2 at an even frame time, so 40 and 45 fps show uneven motion that 30 and 60 do not. **120 fps is not offered:** the step cannot go below 1/60 s, and `DM_PRESENT_HZ=120` ran at 1.84 times real speed. Parts of the menus and the pre-race intro stay at step 1, so they run slower below 60 fps (half speed at 30); why is open. On a 120 Hz screen the cap takes a 120 Hz display link ([A present rate between the link's ticks](../../../docs/reference/frame-rate.md#a-present-rate-between-the-links-ticks)); the Mac used for these runs had a 60 Hz link, so that path is checked only by `t_link_ticks`. `@game_itv` in `DM_NVN_TSV` is the interval the game set each frame.

## Screen shape

**Off (2026-11-14): the game renders its own 16:9.** Measured on the Mac at 19.5:9 (2556x1179), the picture below stretched the 3D and the HUD alike: Mario's cap and the coin icon 1.21-1.22 times as wide as at 16:9, the screen's 2.17 over 1.78. The cause is the first fixed 1280x720 pair of the resolution table (+0x2a0): it is the cameras' aspect and also a scale (width / 1280, height / 720) for the 3D buffers and the final composite, while the final buffer and the crop keep the Screen pair's size, so no table value fixes both (widened: a 2861-wide composite on the 2336-wide screen; 1280x590: an 885-tall one on 1080). The race cameras' aspect is written at `main+0x994c` (from `main+0x7d8c`, about 4 s after boot); a stub there, and nn::ui2d's on-screen DrawInfo projection for the HUD (as nxnative PR #1384 does for Donkey Kong Bananza), are the open work. `screen_shape fill` is left out of `game.tsv`, so the launcher's Picture shape row is hidden. The text below describes the stub as it stands.

The launcher's **Picture shape** (`DM_ASPECT`; current). **Fill the screen**, the default, draws the 3D view at the screen's shape: about 19.5:9 on an iPhone 18 Pro, 4:3 on an iPad, the window's first size on the Mac (`DM_WINDOW_SIZE`, or the screen's with `DM_FULLSCREEN`). The HUD and menus are left as the game draws them at 16:9, unstretched in the middle. **16:9** is the game as on the Switch, with bars. The game takes the shape once, at boot.

- **The 3D view.** `main+0xc0ff60` fills the game's resolution table: twelve (width, height) pairs, the `Screen` and `For3D` sizes of the Middle and Low sets, each width height / 9 x 16. The stub of `patches.py` (`main+0xc10408`, before the render scale) gives every pair the screen's shape: a wider shape keeps the height and widens, a narrower one keeps the width and grows taller, and the pair is then scaled to fit the 2560x1440 window textures the game presents a crop of. Its cameras follow the table, so the scene widens with its geometry right: in handheld at 19.5:9 the screen is 2340x1080, at 4:3 1920x1440; docked at 19.5:9 2560x1182.
- **The HUD.** With only the Middle and Low pairs changed, the layouts were drawn over the whole wider screen, stretched: the coin icon measured 1.24 times as wide as tall against 1.03 at 16:9 (2556x1179, 0.8 render scale, Mario Bros. Circuit). The table's fixed 1920x1080 pair (+0x2a8, not from the config) is the screen the layouts are drawn on: the stub gives it the shape too, and the HUD keeps its 16:9 size and proportions. The two fixed 1280x720 pairs (+0x2a0, +0x2b0) stay as they are: widened too, the whole picture was shifted right. Not the layouts' own size: the game builds its layouts at `main+0x685ce0`, which copies each `lyt1` size into the layout (+0x28, +0x2c) at `main+0x686104` (`nn::ui2d`'s own copy, `main+0x167b1dc`, is never called); every layout of the title, menus and a race is 1920x1080 there (`DM_PROBE`), and widening it changed nothing on screen.
- **The front ends.** The present fits the picture to the drawable on both, so it fills the screen at the game's shape. On iOS the game view and its touches take the game's shape (`front_ios.m` `fit_16_9`, `DmGamepad.m` `pushGame`), and the shape is the screen's in landscape.

## Shaders

- [`pso_manifest.tsv`](pso_manifest.tsv): the Mac's device list (6,110 shaders, 4,238 render pipelines, 175 compute pipelines) of the title, the menus, a pre-race movie and Mario Bros. Circuit.
- From `Shader/*.Nin_Ounce_NVN2.bfsha.zs`, as Donkey Kong Bananza's.
- The game draws with task and mesh shaders (NVN2 stages 6 and 7, `nvnCommandBufferDrawMeshTasks`): they map to the host's slots 3 and 4 and draw through Metal's mesh pipelines (`nvn_mtl.m` `mesh_pso`, `mesh_encode`). Their pixel shaders read flat per-primitive inputs, which the mesh shader writes from its second, geometry-type program header (at the control section's +0x64; `dmsh_meshstage.py`).
- A pixel shader writing an integer target only from flat inputs or constants is built with integer outputs (`dmsh_build.py` `fs_uint`): one R8Uint mesh pipeline was refused without it.

## Terrain

The game stores its terrain tiles (260x260 R16 height, RG8 material, RGBA8 and R11G11B10F colour, 68x68 RGBA16; a `CPU_CACHED` pool) into reused slots before `nvnTextureInitialize` and never flushes them. On NVN2 the GPU reads what the CPU stored, so an uncompressed texture whose first use is a sample is taken from its storage (`tex_cpu_content`, from kartnative 313e90f9; `t_sampled_storage`). Before it the ground was flat and Peach Beach had no sea there.

## Movies

- The cup's pre-race movie is H.264 through the newer `Initialize…Decoder` with parameter sets and `Get…DecoderOutputBufferProperties` with a colour space (`hle_codec_video.c`); without them the game aborted on entering a cup.
- The movie's frames go into an sRGB texture and its linear twin over the same storage. They were two Metal textures, so the presented one stayed on the first frame: an sRGB / linear pair now shares one texture through a view (`nvn_mtl.m`, `tex_mtl_`). The same fixed the missing textures of the title's movies.

## Memory

**Guest memory in 1 GB files (2026-11-14).** `mem_file` maps the guest block from files of `DM_MEM_FILE_CHUNK` bytes (default 1 GB; 14 for this game) instead of one file of the whole block, as nxnative's guest files do (865cc35f): the stall at the system's periodic flush of a shared file grows with the file, and with one 13 GB file a Mac race at render scale 1.0 froze at frame 4,500 under memory pressure, the process stuck in the kernel with about 4 GB wired until a restart. With the files a race at 0.75 ran clean (60 fps, frame p95 19 ms); at 1.0 under pressure not yet run. On the Mac `DM_MEM_FILE=0` avoids the files for testing.

**Recycled render-target memory (2026-11-14).** Render and shader-write targets in GPU-only pools come from a list of placement heaps that wait resident after their texture goes (nxnative 7f502220, 707cac95; `DM_NVN_RT_RECYCLE=0` turns it off). Upstream measured this game's dynamic resolution, which resizes its targets nearly every frame under GPU load, adding 1.8 GB of texture memory per 300 race frames before and 0.34 GB after. On the Mac the GPU stays in budget, so dynamic resolution does not move: a race made 1,892 heaps and reused 2,430 at loading, frame times unchanged.

The limit on an iPhone 18 Pro in LiveContainer is 8,192 MiB (footprint plus `os_proc_available_memory`, in the log's `on-screen up to frame` lines). With `mem_file` and `tex_soft` a whole cup ran there at 3.9 GB. What the host does:

- Memory pools get their zero-copy Metal buffer on first GPU use (`pool_buf`): 2,765 of 5,230 pools never get one.
- `tex_soft` keeps large block-compressed textures without their finest level, gives back the pages only that level holds, and uploads packaged textures on the CPU while their pool has no buffer. The GPU's upload would give the pool one, and iOS wires a buffer's whole pool: wrapped pools fell from 3.7 GB to 851 MB on the iPhone. The game copies source textures into its terrain arrays, and those stay whole (`soft_harden`): with the copy skipped, the road was purple.
- Sparse tiles follow physical pages: a page mapped in two places or textures takes one tile, uploaded again only when the game writes the page (`nvn_dirty_since`); with `tex_release` and guest memory anonymous, the uploaded pages go back to the system (`nvn_dirty_release`, about 860 MB; with `mem_file` they are the file's and stay).
- `mem_file` puts guest memory in a shared mapping of a file. It froze the game on the iPhone when it first wired the 2.4 GB main pool; with CPU uploads that pool has no buffer, and the rest (about 870 MB, largest 232 MB) wires in milliseconds. A 7 MB pool took 16 s on a Mac short of memory: expect stalls if the phone itself runs short.

**Texture memory: Low** (launcher, Performance; `DM_NVN_TEX_SOFT=2`): textures of 1024x512 and larger are kept without their two finest levels, a sixteenth of their size; smaller soft ones keep one level less as before. For phones with less memory than the iPhone 18 Pro. Levels the game names in views and copies are two lower there (`tex_soft_level`); a view of a dropped level starts at the finest kept one. On the Mac (2026-11-09, Mario Bros. Circuit, windowless, 19.5:9, 75 %): by the 3,000th soft texture Standard had left out 842 MB of GPU memory and Low 1,028 MB (1,295 of them two levels down); at frame 4,200 GPU allocated was 3,931 MB against 3,641 MB, resident 4,499 against 4,204 MB, about 290 MB less. No broken textures in its shots; not yet seen on a phone. The log line `soft textures: N made (…), M MB of GPU memory not kept` gives the tally.

Releasing the packaged textures' guest copies (about 2 GB) gave magenta textures: new textures came about 0x200 bytes below kept, released ones whose ranges had been written. It is off (`PKG_RELEASE` in `nvn_mtl.m`).

## Open

- Screen shape: split screen (two to four players), the menus' touch input on the wider picture, docked, and the iPad's 4:3 are not checked; on the iPhone it is checked on the Mac only, at its 2556x1179 shape.
- The frame rate drop may be the game moving to the efficiency cores while the phone is cool. In two iPhone runs, one Handheld and one Docked, it went from about 50 % to 2-3 % on performance cores at about 1.6 GHz, CPU energy 2 W to 0.4 W, submit+present p50 4 ms to 16 ms, GPU unchanged in Handheld, thermal 0 in Handheld and 1 in Docked. Those two runs had Frame buffering and Metal 4 pipelines on; a run with both off held 60 fps for its 106 s, too short to rule out the drop, and at half the screen brightness. The Frame-step probes ([Power](../../../docs/development.md)) that recover Tears of the Kingdom from this need a frame step, which this game has not.
- Trees disappearing and popping back was reported on the iPhone, with no course or log yet. The game has `FoliageCulling`, `ImpostorCulling` and `HiZ Texture`; [A store only a dispatch's first invocation makes](../../../docs/reference/shaders.md#a-store-only-a-dispatchs-first-invocation-makes) is the first thing to rule out.
- 60 fps on the iPhone. For the first 53-70 s a race holds 60 fps with GPU p50 8 ms and the CPU at 4.7 GHz, about 4.2 W. Then, at similar draw counts, either the GPU takes 21 ms (about 38 fps, CPU 4.4 GHz, 2.1 W) or the CPU falls to 2.1 GHz with the GPU at 8 ms (about 46 fps); it can return to 60 fps for a while. A cold phone slows at the same time. Ruled out: `DM_NVN_BARRIER=game`, `DM_NVN_TBDR=1` (no change in traffic, about 415 MB loaded and 455 MB stored a frame), `DM_RT=0`. `DM_QOS_MAP=1` was reported with missing textures.
- A margin in a race on courses other than Mario Bros. Circuit.
- Frame rate in a race on the Mac: about 50 fps. Frames take about 12 ms of submit and present and 11-19 ms of GPU, and after a late one the game sets present interval 2 for a frame (`main+0x3aa0a4`, about 1,260 times in a 4-minute run).

## Found on this game

- [A present rate between the link's ticks](../../../docs/reference/frame-rate.md#a-present-rate-between-the-links-ticks)
