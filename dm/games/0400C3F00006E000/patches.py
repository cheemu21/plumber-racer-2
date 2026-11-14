# Mario Kart World (0400C3F00006E000): the rewriter's patches of this game's own builds. dm/tools/patch_nso.py loads every profile's patches.py as described there ("Registered patches")
from nso_asm import ADRP, B

# Render scale (state +0x10, float written by the loader: DM_RENDER_SCALE, 1.0 by default). main+0xc0ff60 builds the object holding the game's resolution table: each (width, height)
# comes from game__GamePerformanceGraphicsConfig (ResolutionMiddleFor3D, ...Screen, ...ForDiv, ...ForDiv4, and the Low set; main+0x1c6cad4 names them), the height capped at 1440 and the
# width height / 9 * 16. The 3D entries size the scene apart from the screen, so scaling them leaves the screen's size and the HUD as they are. The table is filled once, so the stub runs
# once, right after the last entry is stored (main+0xc10408). x8, x9 and s0-s1 are dead there: w8 is set by the replaced instruction, and the next call is main+0xc10410. Sizes stay even
# (half-size passes) and round to nearest: fcvtzs would take 1343 from 1920 x 0.7. The game's own dynamic resolution (profile gpu_timestamps segment) steps down from these sizes. 1.0 = bit-exact original
cfg_3d = (0x2e0, 0x2e4, 0x2f0, 0x2f4, 0x300, 0x304, 0x310, 0x314, 0x320, 0x324, 0x330, 0x334)   # the (width, height) of Middle, MiddleForDiv, MiddleForDiv4, Low, LowForDiv, LowForDiv4

# Screen shape (state +0x14, float width / height written by the loader: DM_ASPECT, the screen's or window's shape by default; 0 = the game's 16:9). The same table's widths are
# height / 9 * 16, the Screen entries as well as the 3D ones (cfg_all: each pair's width, then its height). Before the render scale, the stub gives every pair the screen's shape: a wider
# shape keeps the height (width = height x aspect), a narrower one keeps the width (height = width / aspect); the pair is then scaled down to fit the window textures (the game makes them
# 2560x1440 and presents a crop of them), the width rounded to 16 as the game's own are, the height to 2. The fixed 1920x1080 pair (+0x2a8, not from the config) gets the shape too.
# OPEN (2026-11-13): the 3D and the HUD are still stretched at 19.5:9 (Mario's cap and the coin 1.21-1.22 times as wide as at 16:9). The first fixed 1280x720 pair (+0x2a0, copied
# with +0x2a8 into a display description at main+0x99ea40) gives the cameras their aspect, and the game multiplies the 3D buffers and the final composite by its width / 1280 and height / 720,
# while the final buffer and the crop stay the Screen pair's size: widened, the composite was 2861 wide on the 2336-wide screen (cut on the right); 1280x590, 885 tall on 1080. No table
# value fixes both: the reader that turns the pair into the cameras' aspect needs a stub. The second (+0x2b0) and the lens constructors (main+0x9ef5e4, main+0xd33588) change nothing
cfg_all = (0x2a8,) + tuple(range(0x2d8, 0x338, 8))   # the fixed 1920x1080 (the UI's screen), then the Middle and Low sets
win_w, win_h = 2560, 1440

# Game speed. sead::GameFrameworkOunce's frame (main+0x3a9e28) steps game time by the present interval it picks, 1 or 2 sixtieths of a second: it adds this frame's time less the interval's
# to a running sum (+0x218, limited to 1/15 s) and takes interval 2 once the sum passes 1/60 s. The time it reads, +0x128, stops before the wait for the present (+0xe8 is the whole frame),
# which on the Switch lets a frame that merely waits for its vsync count as on time. Here a frame also waits for the display link and for the present rate (DM_PRESENT_HZ), so the sum never
# saw them and the game ran slow: 0.5 of real time at a 30 fps cap, about 0.87 on an iPhone at 45 fps. Reading the whole frame gives 1, 1, 2 at 45 fps, 1, 2 at 40 and 2 at 30. Above 60 fps
# nothing can keep the speed, as the step cannot go below 1/60 s (DM_PRESENT_HZ=120 ran at 1.84 times real speed)
def frame_step(ctx):
    here, emit = ctx.here, ctx.emit
    ctx.site(0x3a9f0c, '689640f9')   # ldr x8,[x19,#0x128]
    ctx.put(0x3a9f0c, [0xf9407668], 'interval logic: the whole frame time, with the wait for the present')   # ldr x8,[x19,#0xe8]
    ctx.site(0xc10408, '2800a052')   # mov w8,#0x10000
    start = here(); emit(ADRP(8, here(), ctx.state))
    assert (win_w, win_h) == (2560, 1440)   # 0x45200000 and 0x44b40000 below
    per = 22   # instructions of one entry's shape
    cam = 0   # the cameras' pair is left as the game sets it (below)
    for w in (0xbd401510,   # ldr s16,[x8,#0x14]      aspect
              0x1e202208,   # fcmp s16,#0.0
              0x5400000d | (10 + per * len(cfg_all) + cam + 1) << 5,   # b.le scale        not set: the game's 16:9
              0x52a8a409, 0x1e270132,   # mov w9,#0x45200000; fmov s18,w9      2560.0
              0x52a7b009, 0x1e270134,   # mov w9,#0x3d800000; fmov s20,w9      1/16
              0x52a7fc69, 0x7291c729, 0x1e270137,   # mov w9,#0x3fe38e39; fmov s23,w9   16/9
              0x52a89689, 0x1e27013a,   # mov w9,#0x44b40000; fmov s26,w9      1440.0
              0x1e2e101b):  # fmov s27,#1.0
        emit(w)
    for off in cfg_all:
        lo, hi = (off // 4) << 10, ((off + 4) // 4) << 10
        for w in (0xb9400269 | lo, 0x1e220135,   # ldr w9,[x19,#off]; scvtf s21,w9      game width
                  0xb9400269 | hi, 0x1e220136,   # ldr w9,[x19,#off+4]; scvtf s22,w9    game height
                  0x1e300ad1,   # fmul s17,s22,s16       height x aspect
                  0x1e301ab3,   # fdiv s19,s21,s16       width / aspect
                  0x1e372200,   # fcmp s16,s23
                  0x1e35ae31,   # fcsel s17,s17,s21,ge   width: wider keeps the height, narrower the width
                  0x1e33aed3,   # fcsel s19,s22,s19,ge   height
                  0x1e311a58,   # fdiv s24,s18,s17       2560 / width
                  0x1e331b59,   # fdiv s25,s26,s19       1440 / height
                  0x1e397b18,   # fminnm s24,s24,s25
                  0x1e3b7b18,   # fminnm s24,s24,s27     at most 1: fit the window textures
                  0x1e380a31, 0x1e380a73,   # fmul s17,s17,s24; fmul s19,s19,s24
                  0x1e340a31, 0x1e200229, 0x531c6d29, 0xb9000269 | lo,   # width in 16s: fmul s17,s17,s20; fcvtns w9,s17; lsl w9,w9,#4; str w9,[x19,#off]
                  0x1e20026a, 0x121f794a, 0xb900026a | hi):   # height even: fcvtns w10,s19; and w10,w10,#~1; str w10,[x19,#off+4]
            emit(w)
    skip = 6 * len(cfg_3d) + 1   # instructions from the b.eq to the original instruction (6 per field, then itself)
    for w in (0xbd401100,   # ldr s0,[x8,#0x10]       render scale
              0x1e202008,   # fcmp s0,#0.0
              0x5400000d | (skip + 3) << 5,   # b.le done              not set
              0x1e2e1001,   # fmov s1,#1.0
              0x1e212000,   # fcmp s0,s1
              0x54000000 | skip << 5):   # b.eq done              1.0: the game's own sizes
        emit(w)
    for off in cfg_3d:
        for w in (0xb9400269 | (off // 4) << 10,   # ldr w9,[x19,#off]
                  0x1e220121,   # scvtf s1,w9
                  0x1e200821,   # fmul s1,s1,s0
                  0x1e200029,   # fcvtns w9,s1
                  0x121f7929,   # and w9,w9,#~1
                  0xb9000269 | (off // 4) << 10):   # str w9,[x19,#off]
            emit(w)
    emit(0x52a00028)   # done: mov w8,#0x10000 (original)
    emit(B(here(), 0xc1040c))
    ctx.put(0xc10408, [B(0xc10408, start)], 'resolution table: the screen shape (DM_ASPECT), then the 3D sizes x the host render scale (1.0 = original)'); ctx.render_scale = 1

FRAME_STEP = {'9e244438c3d8ef1c703a6a85ef99c4f0': frame_step}

# How general each patch is and could be (dm/tools/docs_patches.py "Binding", listed in docs/agents/game-patches.md)
BINDING = [
    {'what': 'render scale, screen shape and game speed at any present rate', 'now': 'build', 'goal': 'game', 'purpose': 'frame rate',
     'why': "the game's own resolution table and frame loop",
     'blocked': 'frame-step stubs have no function-matched form yet'},
]
