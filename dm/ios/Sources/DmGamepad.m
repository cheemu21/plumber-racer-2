// Virtual gamepad (Nintendo button positions) + physical controllers (GameController), handed to the host through dm_input_set and dm_pad_set_player (hle_hid.c, bit layout in dm_input.h).
//   Two layouts, three in handheld mode; one tap on the layout button at the top centre (labelled with the current layout, "2D" / "3D" / "Tap") goes to the next, and the choice is kept in NSUserDefaults (each game is its own app, so per game); the first launch uses the game profile's pad_layout (DM_GAME_PAD_LAYOUT).
//   Tap (touch): no control but the layout button, every other touch goes to the game's touch screen; offered only while the game is in handheld mode, the only one in which it reads the touch screen (Balatro, played by touch).
//   2D (simple): top corners ZL above L (one column), ZR above R likewise, teardrops with the tip toward the screen corner; − and + side by side at the top centre; the left stick in the bottom-left corner (fixed ring, tilt measured from the ring centre, small dead zone);
//     the A (right) B (bottom) X (top) Y (left) diamond in the bottom-right corner, sliding a finger between keys switches keys. Each bottom corner holds a single control, so it sits close in (reaching halfway into the side safe-area inset).
//   3D (full, Pro Controller style): everything in 2D (left stick and diamond keep their place and size), plus a D-pad (inward of and below the left stick, 8-way), a right stick that is not drawn
//     (a touch landing in the right third of the screen on no control holds it: centred where it lands, the centre dragged along once the finger passes the stick radius) and L3 / R3 (small round keys in the top row, inward of ZL / ZR).
//     Breath of the Wild crouches with L3 and uses the scope with R3; 3D World and Breath of the Wild turn the camera with the right stick.
//   Touch-down ownership: locked keys first (shoulders, − / +, the layout button, L3 / R3), then whichever of the diamond, the D-pad and the left stick has the smallest distance / grab radius (the left stick's grab circle borders the D-pad),
//     then in 3D the right stick for a touch in the right third.
//   Everything hugs the edges and corners to leave the picture room; controls sit over the picture, one CAShapeLayer each: a press only swaps the fill, a stick only moves its knob, nothing redraws the whole screen.
//   Touches no control takes (in 3D, those outside the right third) go to the game's touch screen (pushGame; Super Mario Galaxy's pointer in handheld mode).
//   The virtual gamepad (layout button included) hides while a physical controller is connected and comes back when it is removed; meanwhile every touch goes to the game. Physical controllers keep every button (D-pad and right stick included) and map by position: bottom = B, right = A, left = Y, top = X (same positions as on a Switch controller); a Nintendo pad maps by its labels (pad_apple.h).
//   Each physical controller is a player of its own (local co-op), as on the Mac: the first one connected is player 1, together with the touch gamepad, the next player 2, and so on up to 8; see "Physical controllers" below.
//   Shaking the phone shakes the controller (DM_BTN_SHAKE: its six-axis sensor, hle_hid.c), whichever controls are in use; see "Shaking the phone" below.
#import <UIKit/UIKit.h>
#import <GameController/GameController.h>
#import <CoreMotion/CoreMotion.h>
#import <CoreText/CoreText.h>
#include <pthread.h>
#include "dm.h"
#include "dm_input.h"
#include "front.h"
#include "game_profile.h"
#include "haptics_apple.h"
#include "motion_apple.h"
#include "motion_fusion.h"
#include "pad_apple.h"
#include "pad_slots.h"
#include <stdatomic.h>

enum { B_A = 0, B_B, B_X, B_Y, B_LS, B_RS, B_L, B_R, B_ZL, B_ZR, B_PLUS, B_MINUS, B_LEFT, B_UP, B_RIGHT, B_DOWN, B_N };
enum { C_NONE = 0, C_STICK, C_DPAD, C_FACE, C_BTN, C_SWAP, C_GAME, C_EMPTY, C_GESTURE };   // which control a touch holds; C_GAME: none, the touch goes to the game's touch screen (finger slot << 8); C_EMPTY: none, kept (the kart style's two-finger tap); C_GESTURE: none while the kart controls are hidden (a tap, swipe or long press standing in for a button)

static pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER;
static uint64_t g_touch_btn, g_shake_btn;
static int32_t g_touch_lx, g_touch_ly, g_touch_rx, g_touch_ry;
static void publish(void) {   // the touch gamepad and the shake; the host ORs them with player 1's controller and takes whichever stick is deflected more (hle_hid.c)
    pthread_mutex_lock(&g_mu);
    dm_input_set(g_touch_btn | g_shake_btn, g_touch_lx, g_touch_ly, g_touch_rx, g_touch_ry);
    pthread_mutex_unlock(&g_mu);
}

// ---- Shaking the phone ----
// The accelerometer at 60 Hz (no gyroscope, no permission prompt): gravity is followed by a slow low-pass (about 0.8 s), and a sample whose acceleration beyond it exceeds DM_SHAKE_G
// (1.5 G by default; Documents/env.txt overrides) is a hit. The controller is shaken until 120 ms after the last hit: a flick is one shake (the host finishes it as a whole cycle)
// and shaking on keeps it going. Holding the phone and pressing the screen stays far below the threshold. Each detected shake is logged with its peak
static CMMotionManager *g_motion;
static void motion_start(void) {
    if (g_motion) return;
    g_motion = [CMMotionManager new];
    if (!g_motion.accelerometerAvailable) { LOG("front end: no accelerometer, shaking the phone does nothing"); return; }
    const char *e = getenv("DM_SHAKE_G"); double thr = e && atof(e) > 0 ? atof(e) : 1.5;
    LOG("front end: shaking the phone shakes the controller (threshold %.2f G)", thr);
    g_motion.accelerometerUpdateInterval = 1.0 / 60;
    NSOperationQueue *q = [NSOperationQueue new]; q.maxConcurrentOperationCount = 1;
    __block double gx = 0, gy = 0, gz = 0, last = -1, peak = 0; __block BOOL init = NO;
    [g_motion startAccelerometerUpdatesToQueue:q withHandler:^(CMAccelerometerData *d, NSError *err) {
        (void)err; if (!d) return;
        CMAcceleration a = d.acceleration;
        if (!init) { gx = a.x; gy = a.y; gz = a.z; init = YES; }
        double dx = a.x - gx, dy = a.y - gy, dz = a.z - gz, g = sqrt(dx * dx + dy * dy + dz * dz);
        gx += (a.x - gx) * 0.02; gy += (a.y - gy) * 0.02; gz += (a.z - gz) * 0.02;
        if (g > thr) { if (last < 0) peak = 0; last = d.timestamp; peak = fmax(peak, g); }
        BOOL on = last >= 0 && d.timestamp - last < 0.12;
        if (!on && last >= 0) { LOG("front end: phone shaken (peak %.1f G)", peak); last = -1; }
        uint64_t want = on ? DM_BTN_SHAKE : 0;
        pthread_mutex_lock(&g_mu); BOOL changed = g_shake_btn != want; g_shake_btn = want; pthread_mutex_unlock(&g_mu);
        if (changed) publish();
    }];
}

@interface DmGamepad : UIView
- (void)pulse:(uint64_t)mask ms:(int)ms;   // buttons held for a moment by a gesture (the phone's forward flick presses L from the motion handler)
- (void)pulse:(uint64_t)mask ly:(int32_t)ly ms:(int)ms;   // the same with the left stick held at ly (a backward flick: the item thrown backwards is down + L)
@end

// ---- The phone's gyro ----
// A controller mounted on the phone (Backbone One, Razer Kishi, GameSir G8) has no motion sensors of its own: the phone in the middle is the console, as a Switch in handheld.
// So the phone's device motion (gyro + accelerometer, CoreMotion's fused gravity and user acceleration, 100 Hz, no permission prompt) drives player 1's six-axis sensor, turned
// into the Switch frame for the screen's orientation (motion_phone_to_switch, motion_fusion.h): x to the right of the picture, y to its top, z toward the player.
// The host keeps phone and controller orientations separately, choosing fresh controller data in auto mode and the phone alone in forced mode.
// DM_PHONE_MOTION: auto (default) while no controller supplies fresh gyro data (a DualSense held apart from the phone uses its own, motion_apple.h), 1 always, 0 never.
// DM_MOTION=0 (all live motion off; the NSP script's --no-motion builds it in) never starts device motion.
// Which frame the samples come in: on iOS 27 and later the pad view (full screen, over the picture) is the motion body (CMMotionManager.deviceMotionBody), so Core Motion delivers
// them in that view's frame for whichever display shows it and however it is turned: x to the right of the picture, y to its top, z toward the player, the Switch frame as it is.
// Before that they come in the hardware frame, turned here by the interface orientation, which holds only where the hardware frame is the screen's portrait frame: not on iPhone
// Duo's inner display, whose picture is a quarter turn from it (up / down and left / right swapped, GitHub issue #569). Open: while the scene is not full screen (Split View on the
// inner display) Core Motion falls back to the hardware frame without saying so, and the samples are then taken as the view's frame
static _Atomic int g_iface_orient = 3;      // UIInterfaceOrientation, updated on layout
static _Atomic int g_pad_shown = 1;         // the kart controls are on screen (a race): the flicks act only then
static float g_motion_gain = 1.0f;         // DM_MOTION_GAIN (the launcher's Tilt sensitivity, 0.5 to 2.0): how far the phone's tilt and turn rates reach the game's motion sensor
static BOOL g_flick_item;                  // DM_FLICK_ITEM (the launcher's Flick for an item, kart style): a sharp forward flick of the phone presses L, Mario Kart's item button; a backward flick adds stick-down to throw it behind
static BOOL g_motion_body;                  // samples in the body's frame (iOS 27+)
static void phone_motion_start(UIView *body) {
    const char *e = getenv("DM_MOTION");
    if (e && !atoi(e)) { LOG("front end: motion is off (DM_MOTION=0), the phone's gyro is not used"); return; }
    e = getenv("DM_PHONE_MOTION"); int mode = !e || !strcmp(e, "auto") ? -1 : atoi(e);
    if (!mode) { LOG("front end: the phone's gyro is off (DM_PHONE_MOTION=0)"); return; }
    if (!g_motion.deviceMotionAvailable) { LOG("front end: no device motion, the phone's gyro is not used"); return; }
    LOG("front end: the phone's gyro drives the controller's six-axis sensor %s", mode < 0 ? "while no controller supplies fresh motion" : "always (DM_PHONE_MOTION=1)");
    { const char *gs = getenv("DM_MOTION_GAIN"); float gn = gs ? strtof(gs, NULL) : 1.0f; g_motion_gain = gn >= 0.5f && gn <= 2.0f ? gn : 1.0f;
      const char *fl = getenv("DM_FLICK_ITEM"); g_flick_item = DM_GAME_PAD_STYLE >= 2 && (!fl || atoi(fl));   // the kart styles (g_kart is defined further down)
      if (g_motion_gain != 1.0f) LOG("front end: tilt sensitivity %.0f %% (DM_MOTION_GAIN)", g_motion_gain * 100);
      if (g_flick_item) LOG("front end: a sharp forward flick of the phone presses L, the item button, while the kart controls are shown (DM_FLICK_ITEM=0 turns it off)"); }
    __weak UIView *wbody = body;
    g_motion.deviceMotionUpdateInterval = 1.0 / 100;
    if (@available(iOS 27.0, *)) { g_motion.deviceMotionBody = body; g_motion_body = YES; LOG("front end: the phone's motion comes in the pad view's frame (deviceMotionBody)"); }
    NSOperationQueue *q = [NSOperationQueue new]; q.maxConcurrentOperationCount = 1;
    [g_motion startDeviceMotionUpdatesToQueue:q withHandler:^(CMDeviceMotion *d, NSError *err) {
        (void)err; if (!d) return;
        float a[3] = {(float)(d.gravity.x + d.userAcceleration.x), (float)(d.gravity.y + d.userAcceleration.y), (float)(d.gravity.z + d.userAcceleration.z)};
        float w[3] = {(float)d.rotationRate.x, (float)d.rotationRate.y, (float)d.rotationRate.z}, as[3], ws[3];
        int o = g_motion_body ? 1 : atomic_load(&g_iface_orient);   // the body's frame is already the picture's: the portrait map, which leaves it as it is
        motion_phone_to_switch(o, a, as); motion_phone_to_switch(o, w, ws);
        if (g_motion_gain != 1.0f) {   // sensitivity: the turn rates scaled, and the tilt about the picture's depth axis (the kart's steering: gravity's x share) widened, the vector kept at its length
            float m0 = sqrtf(as[0] * as[0] + as[1] * as[1] + as[2] * as[2]); as[0] *= g_motion_gain;
            float m1 = sqrtf(as[0] * as[0] + as[1] * as[1] + as[2] * as[2]); if (m1 > 0) for (int i = 0; i < 3; i++) as[i] *= m0 / m1;
            for (int i = 0; i < 3; i++) ws[i] *= g_motion_gain;
        }
        // The forward flick: a turn about the picture's x axis (its top edge dipping away from or toward the player) faster than 4.5 rad/s, once per 0.6 s, with the kart controls shown.
        // Steering tilts the phone about its depth axis, which this never reaches
        if (g_flick_item && atomic_load(&g_pad_shown)) {   // the top edge dipping away is a negative turn (measured: forward flicks -4.7 to -6.5 rad/s); toward the player, positive: the item thrown backwards (stick down + L)
            static double lastFlick; double now = d.timestamp;
            if (fabsf(w[0]) > 4.5f && now - lastFlick > 0.6) { lastFlick = now; BOOL back = w[0] > 0; LOG("front end: %s flick (%.1f rad/s): %s", back ? "backward" : "forward", w[0], back ? "down + L, the item thrown backwards" : "L, the item");
                dispatch_async(dispatch_get_main_queue(), ^{ UIView *b = wbody; if (b) { if (back) [(DmGamepad *)b pulse:1ull << B_L ly:-32767 ms:200]; else [(DmGamepad *)b pulse:1ull << B_L ms:150]; } }); }
        }
        dm_motion_set_switch(0, as, ws);
    }];
}

// ---- Layout constants (in u; x measured from the outer edge, the right half mirrors) ----
static const CGFloat
    K_ZL_X = 44, K_ZL_Y = 40, K_ZL_R = 26,          // ZL / ZR: centre from the outer edge and the top, radius
    K_L_X = 44, K_L_Y = 108, K_L_R = 24,            // L / R: same column as ZL / ZR
    K_DROP_TIP = 1.45,                              // teardrop tip distance from the centre (times the radius)
    K_CORNER_IN = 0.5,                              // how far the bottom-corner controls reach into the side safe-area inset (in landscape there is only the rounded screen corner there; the Dynamic Island is mid-edge)
    K_FACE_X = 81, K_PAD_Y = 82,                    // diamond centre from the outer edge; diamond and stick centre from the bottom (B's lower edge about 5 above it)
    K_FACE_GAP = 50, K_FACE_R = 27,                 // diamond: key distance from the centre, key radius
    K_PILL_DX = 52, K_PILL_Y = 22, K_PILL_W = 50, K_PILL_H = 28,   // − / +: centre from the screen's midline (the middle goes to the layout button) and from the top, size
    K_SWAP_R = 15,                                  // layout button: top centre, level with − / +
    K_STICK_X = 81, K_STICK_R = 77, K_KNOB_R = 30,  // left stick: mirrors the diamond, the ring as large as the whole diamond (key distance + key radius), the knob a little larger than a diamond key
    K_STICK_GRAB = 1.4,                             // how near the ring centre a touch-down grabs a stick (times the ring radius)
    K_FULL = 0.8,                                   // full tilt at this fraction of the ring radius (the knob still travels to the ring edge)
    K_DEAD = 0.1,                                   // stick dead zone (times the ring radius)
    // controls only the 3D layout has
    K_LOW_X = 231, K_LOW_Y = 64,                    // D-pad centre from the outer edge and the bottom (inward of and below the left stick, as on a Pro Controller)
    K_DPAD_R = 48, K_ARM_W = 17, K_ARM_IN = 11,     // D-pad: arm outer edge from the centre, half-width, tip from the centre
    K_DPAD_GRAB = 1.3,                              // D-pad grab radius (times the outer edge)
    K_RSTICK_R = 60,                                // right stick (not drawn): radius around its centre, the touch-down point
    K_RSWIPE = 1.0 / 3,                             // right stick area: this fraction of the screen width from the right edge (not in u)
    K_CLICK_X = 102, K_CLICK_R = 17;                // L3 / R3: centre from the outer edge (level with ZL / ZR), radius
// pad_style mobile (DM_GAME_PAD_STYLE): a phone game's layout. x from the outer edge; y from the bottom of the corner rectangle (keys, stick, D-pad) or the top of the safe area (pills)
static const CGFloat
    M_A_X = 82, M_A_Y = 79, M_A_R = 47,             // A: the large key the thumb rests on
    M_B_X = 173, M_B_Y = 43, M_B_R = 31,            // B, Y and X in an arc around it
    M_Y_X = 167, M_Y_Y = 142, M_X_X = 63, M_X_Y = 175, M_XY_R = 28,
    M_STICK_X = 120, M_STICK_Y = 79, M_STICK_R = 64,   // the left stick's resting place and ring radius
    M_ZONE_W = 345, M_ZONE_H = 194,                 // floating stick area: a touch there centres the stick under it (from the left and the bottom of the corner rectangle)
    M_DPAD_X = 271, M_DPAD_Y = 50, M_DPAD_R = 38, M_ARM_W = 13, M_ARM_IN = 8,   // D-pad (3D layout): smaller than the classic one, its bottom arm 12 above the edge
    M_ZL_X = 45, M_ZL_Y = 157, M_ZL_W = 72, M_ZL_H = 34,   // ZL / ZR pills: centre from the outer edge and the top, size
    M_L_X = 133, M_L_Y = 184, M_L_W = 68, M_L_H = 32,      // L / R pills, inward of and below them
    M_PILL_X = 42, M_PILL_Y = 28, M_PILL_W = 46, M_PILL_H = 28;   // − / + in the top corners
// pad_style kart (DM_GAME_PAD_STYLE 2): a racing game's. The mobile style's floating stick and − / + pills, and on the right gas (A) and brake (B) pedals side by side in the corner,
// drift (A and R together, so the kart keeps accelerating) above gas, item (A and L, likewise) left of drift; look back (X, a rear-view mirror) on the left above the stick
// area; the stick's knob a mushroom. Centres in u from the outer edge and the bottom of the corner rectangle. A thumb slides between gas, drift and item without releasing A:
// gas's hit area reaches up to drift's centre, item's across to it, and a face touch that held A keeps it in the gaps between them; one that slid from item to drift keeps holding the item
static const CGFloat
    KT_GAS_X = 80, KT_GAS_Y = 86, KT_GAS_W = 68, KT_GAS_H = 100,
    KT_BRAKE_X = 162, KT_BRAKE_Y = 72, KT_BRAKE_W = 74, KT_BRAKE_H = 74,
    KT_PEDAL_IN = 5,                                // pedals: the bottom edge this much narrower on each side than the top
    KT_DRIFT_X = 102, KT_DRIFT_Y = 212, KT_DRIFT_R = 46,
    KT_ITEM_X = 228, KT_ITEM_Y = 192, KT_ITEM_S = 66, KT_ITEM_TILT = -8 * M_PI / 180,
    KT_BACK_X = 77, KT_BACK_Y = 247, KT_BACK_R = 27,
    KT_REWIND_X = 155, KT_MAP_X = 233,              // pad_style kartworld: rewind (D-pad down) and the map (Y) beside look back, in its row and of its size
    KT_CAPTION = 12;                                // the caption under each control: font size, and its gap below the control
static const int g_mobile = DM_GAME_PAD_STYLE != 0, g_kart = DM_GAME_PAD_STYLE >= 2, g_world = DM_GAME_PAD_STYLE == 3;   // pad_style mobile, or kart (which keeps the mobile style's stick and pills)
static const int g_sinnoh = DM_GAME_PAD_THEME != 0 && !g_kart, g_mono = DM_GAME_PAD_THEME == 2;   // pad_theme sinnoh or mono (the ball drawing; not on the kart style's pedals), mono (in white and gray)
enum { KT_DRIFT_BIT = 63, KT_ITEM_BIT = 62, KT_NCAP = 6 };   // kart: face touches on drift and item hold these pseudo keys, sent as A + R and A + L; captions GAS, BRAKE, DRIFT, ITEM and, on kartworld, REWIND, MAP
static const int k_btns[] = {B_ZL, B_L, B_ZR, B_R, B_MINUS, B_PLUS, B_LS, B_RS};   // keys locked at touch-down (L3 / R3 only in the 3D layout)
static NSString *const k_layout_key = @"DmPadLayout";   // NSUserDefaults: 0 = 2D, 1 = 3D, 2 = Tap (DM_GAME_PAD_LAYOUT's numbers)
int dm_opmode(void);   // hle_oe.c: 0 = handheld

static __weak DmGamepad *g_view;
static void pads_start(void);   // Physical controllers, below

@implementation DmGamepad {
    NSMapTable<UITouch *, NSNumber *> *_owner;     // touch → control (with the key for C_BTN or the stick for C_STICK, << 8)
    UITouch *_stick[2]; CGPoint _stickNow[2];      // the touch holding each stick and where it is now (0 left, 1 right)
    CGPoint _lCentre;                              // pad_style mobile: the floating left stick's centre, where its touch landed
    CAShapeLayer *_cap[B_N + 1], *_band[B_N + 1], *_hub[B_N + 1];   // pad_theme sinnoh: the ball drawing of A / B / X / Y and (index B_N) the stick knob
    CGPoint _rCentre;                              // the right stick's centre: where its touch landed, dragged along past K_RSTICK_R
    uint64_t _faceBits, _dpadBits, _btnBits;
    NSMapTable<UITouch *, NSNumber *> *_faceOf;    // which keys each touch on the diamond currently holds
    CAShapeLayer *_key[B_N]; CATextLayer *_label[B_N];   // one layer per key
    CAShapeLayer *_ring, *_knob;                   // the left stick (the right one is not drawn)
    CAShapeLayer *_swap; CATextLayer *_swapLabel; BOOL _swapHeld;
    UIImpactFeedbackGenerator *_touchFeedback;       // one short feedback per touch-control press edge
    unsigned _hapticSticks;
    BOOL _stickShown;                              // the left stick was held at the last refresh
    BOOL _full, _tap;                              // the 3D layout / the Tap layout is current
    CALayer *_controls;                            // holds every control layer: hidden while a physical controller is connected (the view itself stays, for game touches)
    BOOL _padOff;                                  // a physical controller is connected: every touch goes to the game
    BOOL _kartTouch;                               // pad_style kart with DM_KART_TOUCH=1 (the launcher's Touch on menus): touches no control takes go to the game's touch screen after all
    BOOL _padAuto, _autoHidden;                    // pad_style kart, DM_KART_PAD auto (the launcher's On-screen controls, the default): the controls show while the game draws its world (dm_world_draws,
                                                   // 1,200 and more a frame: races, Free Roam, the title demo) and hide in its menus (150 to 300), where every touch goes to the game's touch screen
    double _drawsEma; int _autoCount; NSTimer *_autoTimer;
    BOOL _lrArmed; uint64_t _pulseMask; int32_t _pulseLy;            // pad_style kart: two fingers down on no control press L and R together for 150 ms (the title screen's "Press L + R"; a single stray touch does nothing);
                                                   // _pulseMask: buttons a gesture holds for a moment (pulse:), added to the mask recompute publishes
    // The hidden controls' gestures (the kart style, DM_KART_PAD auto; Mario Kart World reads the touch screen but acts on nothing in its menus, measured 2026-11-08): a tap presses A,
    // a swipe the D-pad in its direction, a long press B. Per touch: where it began, when, and whether it has fired
    NSMapTable<UITouch *, NSValue *> *_gStart; NSMapTable<UITouch *, NSNumber *> *_gTime; NSHashTable<UITouch *> *_gFired;
    double _lrLast; int _lastHint;                 // the previous two-finger tap's time (a second within 0.45 s shows or hides the controls by hand) and the last file hint acted on (edge-triggered)
    UITouch *_game[16];                            // touches on the game's touch screen by finger slot
    CAShapeLayer *_worldIcon[2];   // pad_style kartworld: the rewind and map icons
    CAShapeLayer *_drift, *_driftIcon, *_groove[2], *_backIcon, *_mush[3];   // pad_style kart: the drift key and its tire marks, the pedals' grip grooves (gas, brake), look back's mirror, the knob's spots, stem and eyes
    CATextLayer *_caption[KT_NCAP];
    BOOL _driftOn;
}

static UIColor *k_idle, *k_on, *k_line, *k_ringFill, *k_text, *k_textOn;
// Per control (index B_N the layout button, B_N + 1 the stick knob): the plain colours, or pad_theme sinnoh's by kind; each carries its own opacity, as above
enum { P_SWAP = B_N, P_KNOB = B_N + 1, P_N };
static UIColor *c_idle[P_N], *c_on[P_N], *c_line[P_N], *c_text[P_N], *c_textOn[P_N], *c_cap, *c_capOn, *c_hub, *c_dark, *c_ringLine;
static UIColor *rgba(int r, int g, int b, CGFloat a) { return [UIColor colorWithRed:r / 255.0 green:g / 255.0 blue:b / 255.0 alpha:a]; }
static void theme_colors(void) {
    for (int i = 0; i < P_N; i++) { c_idle[i] = k_idle; c_on[i] = k_on; c_line[i] = k_line; c_text[i] = k_text; c_textOn[i] = k_textOn; }
    c_ringLine = k_line;
    if (!g_sinnoh) return;
    if (g_mono) {   // the ball keys and knob in white and gray; every other control as plain, with a slightly firmer edge and label
        for (int i = 0; i < P_N; i++) {
            if (i <= B_Y || i == P_KNOB) { c_idle[i] = rgba(255, 255, 255, 0.28); c_on[i] = rgba(255, 255, 255, 0.55); c_line[i] = rgba(255, 255, 255, 0.6); c_text[i] = c_textOn[i] = rgba(34, 34, 34, 0.9); }
            else { c_line[i] = rgba(255, 255, 255, 0.45); c_text[i] = rgba(255, 255, 255, 0.85); }
        }
        c_cap = rgba(255, 255, 255, 0.5); c_capOn = rgba(255, 255, 255, 0.8); c_hub = rgba(255, 255, 255, 0.85); c_dark = rgba(34, 34, 34, 0.55);
        c_ringLine = rgba(255, 255, 255, 0.45);
        return;
    }
    UIColor *dark = rgba(26, 26, 26, 0.9), *white = rgba(255, 255, 255, 0.95);
    for (int i = 0; i < P_N; i++) {
        int ball = i <= B_Y || i == P_KNOB, blue = i == B_L || i == B_R || i == B_ZL || i == B_ZR || i == B_LS || i == B_RS, dpad = i >= B_LEFT && i <= B_DOWN;
        if (ball) { c_idle[i] = rgba(255, 255, 255, 0.55); c_on[i] = rgba(255, 255, 255, 0.85); c_line[i] = rgba(26, 26, 26, 0.65); c_text[i] = c_textOn[i] = dark; }
        else if (blue) { c_idle[i] = rgba(47, 111, 214, 0.55); c_on[i] = rgba(47, 111, 214, 0.88); c_line[i] = rgba(156, 195, 255, 0.85); c_text[i] = c_textOn[i] = white; }
        else if (dpad) { c_idle[i] = rgba(165, 214, 111, 0.5); c_on[i] = rgba(165, 214, 111, 0.88); c_line[i] = rgba(59, 109, 17, 0.8); }
        else { c_idle[i] = rgba(30, 42, 68, 0.6); c_on[i] = rgba(30, 42, 68, 0.88); c_line[i] = rgba(232, 197, 71, 0.85); c_text[i] = c_textOn[i] = white; }   // − / + and the layout button
    }
    c_cap = rgba(227, 53, 13, 0.7); c_capOn = rgba(227, 53, 13, 0.92); c_hub = rgba(255, 255, 255, 0.92); c_dark = rgba(26, 26, 26, 0.7);
    k_ringFill = rgba(30, 42, 68, 0.25); c_ringLine = rgba(156, 195, 255, 0.8);
}
static void ball_parts(CALayer *key, CALayer *below, CAShapeLayer * __strong *cap, CAShapeLayer * __strong *band, CAShapeLayer * __strong *hub) {   // red top half, black band, white centre button, under the key's label
    *cap = [CAShapeLayer layer]; (*cap).fillColor = c_cap.CGColor;
    *band = [CAShapeLayer layer]; (*band).fillColor = nil; (*band).strokeColor = c_dark.CGColor;
    *hub = [CAShapeLayer layer]; (*hub).fillColor = c_hub.CGColor; (*hub).strokeColor = c_dark.CGColor;
    for (CAShapeLayer *l in @[*cap, *band, *hub]) { if (below) [key insertSublayer:l below:below]; else [key addSublayer:l]; }
}
static void ball_paths(CAShapeLayer *cap, CAShapeLayer *band, CAShapeLayer *hub, CGPoint c, CGFloat r) {
    CGMutablePathRef p = CGPathCreateMutable(); CGPathAddArc(p, NULL, c.x, c.y, r, M_PI, 2 * M_PI, false); CGPathCloseSubpath(p);   // through 3π/2: the top half on screen
    cap.path = p; CGPathRelease(p);
    p = CGPathCreateMutable(); CGPathMoveToPoint(p, NULL, c.x - r, c.y); CGPathAddLineToPoint(p, NULL, c.x + r, c.y);
    band.path = p; band.lineWidth = fmax(2, r * 0.11); CGPathRelease(p);
    CGPathRef h = CGPathCreateWithEllipseInRect(CGRectMake(c.x - r * 0.39, c.y - r * 0.39, r * 0.78, r * 0.78), NULL);
    hub.path = h; hub.lineWidth = fmax(1.5, r * 0.09); CGPathRelease(h);
}
static CAShapeLayer *shape(CALayer *parent) {
    CAShapeLayer *l = [CAShapeLayer layer];
    l.fillColor = k_idle.CGColor; l.strokeColor = k_line.CGColor; l.lineWidth = 1.5;
    l.shadowColor = UIColor.blackColor.CGColor; l.shadowOpacity = 0.2; l.shadowRadius = 3; l.shadowOffset = CGSizeMake(0, 1);
    [parent addSublayer:l]; return l;
}
static CATextLayer *label(CALayer *parent, NSString *s) {
    CATextLayer *t = [CATextLayer layer];
    t.string = s; t.alignmentMode = kCAAlignmentCenter; t.foregroundColor = k_text.CGColor; t.contentsScale = UIScreen.mainScreen.scale;
    [parent addSublayer:t]; return t;
}
static BOOL fullOnly(int b) { return b == B_LS || b == B_RS || b >= B_LEFT; }   // keys shown only in the 3D layout
static BOOL keyHidden(int b, BOOL full) {   // the mobile style has no L3 / R3; the kart style only gas, brake, look back, item and − / + (drift is a layer of its own)
    if (g_kart) return !(b == B_A || b == B_B || b == B_X || b == B_L || b == B_PLUS || b == B_MINUS || (g_world && (b == B_DOWN || b == B_Y)));
    return (fullOnly(b) && !full) || (g_mobile && (b == B_LS || b == B_RS)); }

- (instancetype)initWithFrame:(CGRect)f {
    if ((self = [super initWithFrame:f])) {
        self.multipleTouchEnabled = YES; self.opaque = NO; self.backgroundColor = UIColor.clearColor;
        // The kart style keeps the touch screen from the game by default (Mario Kart opens menus on a tap, and a touch that misses a pedal would). DM_KART_TOUCH=1, the launcher's
        // Touch on menus, gives the game the touches no control takes, for its menus; the player accepts that a stray tap in a race may open one
        const char *kt = getenv("DM_KART_TOUCH"); _kartTouch = g_kart && kt && atoi(kt);
        const char *kp = getenv("DM_KART_PAD"); _padAuto = g_kart && !(kp && !strcmp(kp, "always"));
        if (_padAuto) { __weak typeof(self) w = self; _autoTimer = [NSTimer scheduledTimerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *tm) { [w autoTick]; }]; }
        const char *feedback = getenv("DM_TOUCH_HAPTICS");
        if (!feedback || atoi(feedback)) {
            _touchFeedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
            [_touchFeedback prepare];
        }
        _owner = [NSMapTable strongToStrongObjectsMapTable]; _faceOf = [NSMapTable strongToStrongObjectsMapTable];
        _gStart = [NSMapTable strongToStrongObjectsMapTable]; _gTime = [NSMapTable strongToStrongObjectsMapTable]; _gFired = [NSHashTable weakObjectsHashTable];
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            // each colour carries its own low opacity instead of lowering the whole view's alpha (that would add an off-screen pass for the full-screen layer)
            k_idle = [UIColor colorWithWhite:1 alpha:0.14]; k_on = [UIColor colorWithWhite:1 alpha:0.45]; k_line = [UIColor colorWithWhite:1 alpha:0.38];
            k_ringFill = [UIColor colorWithWhite:1 alpha:0.06]; k_text = [UIColor colorWithWhite:1 alpha:0.6]; k_textOn = [UIColor colorWithWhite:0 alpha:0.7];
            theme_colors();
        });
        _controls = [CALayer layer]; [self.layer addSublayer:_controls];
        _ring = shape(_controls); _ring.fillColor = k_ringFill.CGColor; _ring.strokeColor = c_ringLine.CGColor;
        _knob = shape(_controls);
        CAShapeLayer *in = [CAShapeLayer layer]; in.fillColor = nil; in.strokeColor = k_line.CGColor; in.lineWidth = 1.5;   // inner ring of the knob
        [_knob addSublayer:in];
        _knob.strokeColor = c_line[P_KNOB].CGColor;
        if (g_sinnoh) { in.hidden = YES; ball_parts(_knob, nil, &_cap[B_N], &_band[B_N], &_hub[B_N]); }
        static NSString *const names[B_N] = {@"A", @"B", @"X", @"Y", @"L3", @"R3", @"L", @"R", @"ZL", @"ZR", @"+", @"−"};
        for (int b = 0; b < B_N; b++) {
            _key[b] = shape(_controls);
            if (names[b]) _label[b] = label(_key[b], names[b]);   // the D-pad arms carry no label
            _key[b].strokeColor = c_line[b].CGColor;
            if (g_sinnoh && b <= B_Y) ball_parts(_key[b], _label[b], &_cap[b], &_band[b], &_hub[b]);
        }
        _swap = shape(_controls); _swapLabel = label(_swap, @""); _swap.strokeColor = c_line[P_SWAP].CGColor;
        if (g_kart) {
            _label[B_L].string = @"?";
            for (int i = 0; i < 2; i++) { _groove[i] = [CAShapeLayer layer]; _groove[i].fillColor = nil; _groove[i].strokeColor = [UIColor colorWithWhite:1 alpha:0.3].CGColor; _groove[i].lineCap = kCALineCapRound;
                [_key[i ? B_B : B_A] insertSublayer:_groove[i] below:_label[i ? B_B : B_A]]; }
            _drift = shape(_controls);
            _driftIcon = [CAShapeLayer layer]; _driftIcon.fillColor = nil; _driftIcon.strokeColor = [UIColor colorWithWhite:1 alpha:0.75].CGColor; [_drift addSublayer:_driftIcon];
            _label[B_X].hidden = YES;
            _backIcon = [CAShapeLayer layer]; _backIcon.fillColor = nil; _backIcon.strokeColor = [UIColor colorWithWhite:1 alpha:0.75].CGColor;
            _backIcon.lineCap = kCALineCapRound; _backIcon.lineJoin = kCALineJoinRound; [_key[B_X] addSublayer:_backIcon];
            static const CGFloat mushFill[3] = {0.55, 0.14, 0.85};   // spots, stem, eyes
            for (int i = 0; i < 3; i++) { _mush[i] = [CAShapeLayer layer]; _mush[i].fillColor = [UIColor colorWithWhite:1 alpha:mushFill[i]].CGColor; [_knob addSublayer:_mush[i]]; }
            _mush[1].strokeColor = [UIColor colorWithWhite:1 alpha:0.5].CGColor;
            static NSString *const caps[KT_NCAP] = {@"GAS", @"BRAKE", @"DRIFT", @"ITEM", @"REWIND", @"MAP"};
            for (int i = 0; i < (g_world ? 6 : 4); i++) _caption[i] = label(_controls, caps[i]);
            if (g_world) {   // Mario Kart World's own: rewind on D-pad down, the Free Roam map on Y. White and round, as look back
                const int nw[2] = {B_DOWN, B_Y}; for (int i = 0; i < 2; i++) { int b = nw[i]; c_idle[b] = c_idle[B_X]; c_on[b] = c_on[B_X]; c_line[b] = c_line[B_X]; _key[b].strokeColor = c_line[b].CGColor; _label[b].hidden = YES;
                    _worldIcon[i] = [CAShapeLayer layer]; _worldIcon[i].fillColor = nil; _worldIcon[i].strokeColor = [UIColor colorWithWhite:1 alpha:0.75].CGColor;
                    _worldIcon[i].lineCap = kCALineCapRound; _worldIcon[i].lineJoin = kCALineJoinRound; [_key[b] addSublayer:_worldIcon[i]]; }
            }
            in.hidden = YES;   // the mushroom knob has no inner ring
        }
        NSNumber *saved = [NSUserDefaults.standardUserDefaults objectForKey:k_layout_key];
        int l = saved ? (int)saved.integerValue : DM_GAME_PAD_LAYOUT;
        if (l == 2 && dm_opmode() != 0) l = 0;   // Tap only in handheld mode (env.txt's DM_OPMODE may have changed it)
        if (g_kart) l = 0;   // the kart style has one layout and no layout button
        _full = l == 1; _tap = l == 2;
        [self applyLayout];
        NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
        [nc addObserver:self selector:@selector(padsChanged:) name:GCControllerDidConnectNotification object:nil];
        [nc addObserver:self selector:@selector(padsChanged:) name:GCControllerDidDisconnectNotification object:nil];
        pads_start();
        [self padsChanged:nil];
        motion_start();
        phone_motion_start(self);
    }
    return self;
}
- (void)applyLayout {   // show / hide the controls for the current layout
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    for (int b = 0; b < B_N; b++) _key[b].hidden = _tap || keyHidden(b, _full);
    _ring.hidden = _knob.hidden = _tap;
    _drift.hidden = _tap; for (int i = 0; i < KT_NCAP; i++) _caption[i].hidden = _tap;
    _swapLabel.string = _tap ? @"Tap" : _full ? @"3D" : @"2D"; _swap.hidden = g_kart;
    [CATransaction commit];
}
- (void)nextLayout {   // 2D → 3D (→ Tap in handheld mode) → 2D: release every touch first (no key stays held), save, lay out again
    int l = _tap ? 0 : _full ? (dm_opmode() == 0 ? 2 : 0) : 1;
    [self reset];
    _full = l == 1; _tap = l == 2;
    [NSUserDefaults.standardUserDefaults setObject:@(l) forKey:k_layout_key];
    [self applyLayout]; [self setNeedsLayout];
}

// ---- Layout (points; computed inside the safe area) ----
- (CGRect)safe { return UIEdgeInsetsInsetRect(self.bounds, self.safeAreaInsets); }
- (CGRect)corner { UIEdgeInsets i = self.safeAreaInsets; i.left *= K_CORNER_IN; i.right *= K_CORNER_IN; return UIEdgeInsetsInsetRect(self.bounds, i); }   // the rectangle the bottom-corner controls use
- (CGFloat)u { return MIN(self.bounds.size.height / 430.0, 1.3); }   // 1 = 430 points tall (iPhone Pro Max landscape)
static CGPoint side(CGRect s, int right, CGFloat dx, CGFloat y) { return CGPointMake(right ? CGRectGetMaxX(s) - dx : CGRectGetMinX(s) + dx, y); }
- (CGPoint)faceCenter { CGRect s = self.corner; CGFloat u = self.u; return side(s, 1, K_FACE_X * u, CGRectGetMaxY(s) - K_PAD_Y * u); }
- (CGFloat)faceGap { return K_FACE_GAP * self.u; }
- (CGFloat)faceR { return K_FACE_R * self.u; }
- (CGFloat)keyR:(int)b { return g_mobile ? (b == B_A ? M_A_R : b == B_B ? M_B_R : M_XY_R) * self.u : self.faceR; }   // each face key's radius
- (CGPoint)facePos:(int)b { CGPoint c = self.faceCenter; CGFloat g = self.faceGap;
    if (g_mobile) { CGRect s = self.corner; CGFloat u = self.u;
        CGFloat dx = b == B_A ? M_A_X : b == B_B ? M_B_X : b == B_X ? M_X_X : M_Y_X, dy = b == B_A ? M_A_Y : b == B_B ? M_B_Y : b == B_X ? M_X_Y : M_Y_Y;
        return CGPointMake(CGRectGetMaxX(s) - dx * u, CGRectGetMaxY(s) - dy * u); }
    switch (b) { case B_A: return CGPointMake(c.x + g, c.y); case B_B: return CGPointMake(c.x, c.y + g); case B_X: return CGPointMake(c.x, c.y - g); default: return CGPointMake(c.x - g, c.y); } }
- (CGPoint)stickHome { CGRect s = self.corner; CGFloat u = self.u;   // the left stick's ring centre (mobile: where it rests while no touch holds it)
    return g_mobile ? side(s, 0, M_STICK_X * u, CGRectGetMaxY(s) - M_STICK_Y * u) : side(s, 0, K_STICK_X * u, CGRectGetMaxY(s) - K_PAD_Y * u); }
- (CGPoint)stickCentre:(int)i { return i ? _rCentre : g_mobile && _stick[0] ? _lCentre : self.stickHome; }
- (CGFloat)stickR:(int)i { return (i ? K_RSTICK_R : g_mobile ? M_STICK_R : K_STICK_R) * self.u; }
- (BOOL)inStickZone:(CGPoint)p { CGRect s = self.corner; CGFloat u = self.u; return p.x <= CGRectGetMinX(s) + M_ZONE_W * u && p.y >= CGRectGetMaxY(s) - M_ZONE_H * u; }   // mobile: the floating stick's area
- (BOOL)inRightArea:(CGPoint)p { CGRect b = self.bounds; return p.x >= CGRectGetMaxX(b) - b.size.width * K_RSWIPE; }
- (CGPoint)dpadCenter { CGRect s = self.corner; CGFloat u = self.u;
    return g_mobile ? side(s, 0, M_DPAD_X * u, CGRectGetMaxY(s) - M_DPAD_Y * u) : side(s, 0, K_LOW_X * u, CGRectGetMaxY(s) - K_LOW_Y * u); }
- (CGFloat)dpadR { return (g_mobile ? M_DPAD_R : K_DPAD_R) * self.u; }
static BOOL isDrop(int b) { return b == B_ZL || b == B_L || b == B_ZR || b == B_R; }
static BOOL isClick(int b) { return b == B_LS || b == B_RS; }
- (CGPoint)dropCenter:(int)b { CGRect s = self.safe; CGFloat u = self.u; BOOL z = b == B_ZL || b == B_ZR;
    if (g_mobile) return side(s, b == B_ZR || b == B_R, (z ? M_ZL_X : M_L_X) * u, CGRectGetMinY(s) + (z ? M_ZL_Y : M_L_Y) * u);
    return side(s, b == B_ZR || b == B_R, (z ? K_ZL_X : K_L_X) * u, CGRectGetMinY(s) + (z ? K_ZL_Y : K_L_Y) * u); }
- (CGRect)dropRect:(int)b { CGPoint c = [self dropCenter:b]; CGFloat u = self.u; BOOL z = b == B_ZL || b == B_ZR;   // mobile: the shoulder pills
    CGFloat w = (z ? M_ZL_W : M_L_W) * u, h = (z ? M_ZL_H : M_L_H) * u; return CGRectMake(c.x - w / 2, c.y - h / 2, w, h); }
- (CGFloat)dropR:(int)b { return (b == B_ZL || b == B_ZR ? K_ZL_R : K_L_R) * self.u; }
- (CGPoint)clickCenter:(int)b { CGRect s = self.safe; CGFloat u = self.u; return side(s, b == B_RS, K_CLICK_X * u, CGRectGetMinY(s) + K_ZL_Y * u); }
- (CGRect)pillRect:(int)b { CGRect s = self.safe; CGFloat u = self.u, w = K_PILL_W * u, h = K_PILL_H * u;
    CGPoint c = CGPointMake(CGRectGetMidX(s) + (b == B_PLUS ? K_PILL_DX : -K_PILL_DX) * u, CGRectGetMinY(s) + K_PILL_Y * u);   // − on the left, + on the right
    if (g_mobile) { w = M_PILL_W * u; h = M_PILL_H * u; c = side(s, b == B_PLUS, M_PILL_X * u, CGRectGetMinY(s) + M_PILL_Y * u); }   // in the top corners
    return CGRectMake(c.x - w / 2, c.y - h / 2, w, h); }
- (CGPoint)swapCenter { CGRect s = self.safe; return CGPointMake(CGRectGetMidX(s), CGRectGetMinY(s) + (g_mobile ? M_PILL_Y : K_PILL_Y) * self.u); }

static CGFloat dist(CGPoint a, CGPoint b) { return hypot(a.x - b.x, a.y - b.y); }
- (CGPoint)kartAt:(CGFloat)dx :(CGFloat)dy right:(BOOL)right { CGRect s = self.corner; CGFloat u = self.u; return side(s, right, dx * u, CGRectGetMaxY(s) - dy * u); }
static CGRect around(CGPoint c, CGFloat w, CGFloat h) { return CGRectMake(c.x - w / 2, c.y - h / 2, w, h); }
- (CGRect)gasRect { CGFloat u = self.u; return around([self kartAt:KT_GAS_X :KT_GAS_Y right:YES], KT_GAS_W * u, KT_GAS_H * u); }
- (CGRect)brakeRect { CGFloat u = self.u; return around([self kartAt:KT_BRAKE_X :KT_BRAKE_Y right:YES], KT_BRAKE_W * u, KT_BRAKE_H * u); }
- (CGPoint)driftCentre { return [self kartAt:KT_DRIFT_X :KT_DRIFT_Y right:YES]; }
- (CGPoint)itemCentre { return [self kartAt:KT_ITEM_X :KT_ITEM_Y right:YES]; }
- (CGPoint)backCentre { return [self kartAt:KT_BACK_X :KT_BACK_Y right:NO]; }
- (CGPoint)rewindCentre { return [self kartAt:KT_REWIND_X :KT_BACK_Y right:NO]; }
- (CGPoint)mapCentre { return [self kartAt:KT_MAP_X :KT_BACK_Y right:NO]; }
- (uint64_t)kartFaceAt:(CGPoint)p grab:(CGFloat)g {   // kart: the face key under the finger, the nearest first; gas reaches up to drift's centre and item across to it
    CGFloat u = self.u, m = (g - 1) * 40 * u;
    if (dist(p, self.driftCentre) <= KT_DRIFT_R * u * g) return 1ull << KT_DRIFT_BIT;
    CGRect item = CGRectInset(around(self.itemCentre, KT_ITEM_S * u, KT_ITEM_S * u), -m, -m);
    item.size.width = fmax(item.size.width, self.driftCentre.x - item.origin.x);
    if (CGRectContainsPoint(item, p)) return 1ull << KT_ITEM_BIT;
    CGRect gas = self.gasRect; CGFloat top = fmin(CGRectGetMinY(gas), self.driftCentre.y);
    gas = CGRectMake(gas.origin.x, top, gas.size.width, CGRectGetMaxY(gas) - top);
    if (CGRectContainsPoint(CGRectInset(gas, -m, -m), p)) return 1ull << B_A;
    if (CGRectContainsPoint(CGRectInset(self.brakeRect, -m, -m), p)) return 1ull << B_B;
    if (dist(p, self.backCentre) <= KT_BACK_R * u * g) return 1ull << B_X;
    if (g_world && dist(p, self.rewindCentre) <= KT_BACK_R * u * g) return 1ull << B_DOWN;
    if (g_world && dist(p, self.mapCentre) <= KT_BACK_R * u * g) return 1ull << B_Y;
    return 0;
}
- (int)btnAt:(CGPoint)p {   // locked keys (tested on touch-down only, then locked)
    CGFloat u = self.u;
    for (int i = 0; i < (int)(sizeof k_btns / sizeof *k_btns); i++) { int b = k_btns[i];
        if (keyHidden(b, _full) || (g_kart && b == B_L)) continue;   // the kart style's item is a face key (kartFaceAt)
        BOOL hit = isDrop(b) && g_mobile ? CGRectContainsPoint(CGRectInset([self dropRect:b], -8 * u, -8 * u), p)
                 : isDrop(b) ? dist(p, [self dropCenter:b]) <= [self dropR:b] * 1.35
                 : isClick(b) ? dist(p, [self clickCenter:b]) <= K_CLICK_R * u * 1.35
                 : CGRectContainsPoint(CGRectInset([self pillRect:b], -8 * u, -8 * u), p);
        if (hit) return b; }
    return -1;
}
- (BOOL)inSwap:(CGPoint)p { return !g_kart && dist(p, self.swapCenter) <= K_SWAP_R * self.u * 1.6; }
- (uint64_t)faceAt:(CGPoint)p {   // keys under the finger in the diamond (between two keys both count)
    if (g_kart) return [self kartFaceAt:p grab:1.1];
    uint64_t m = 0;
    for (int b = B_A; b <= B_Y; b++) if (dist(p, [self facePos:b]) <= [self keyR:b] * 1.25) m |= 1ull << b;
    return m;
}
- (uint64_t)dpadAt:(CGPoint)p {   // 8 directions: 45° each, diagonals press two keys; a small centre circle counts as none
    CGPoint c = self.dpadCenter; CGFloat dx = p.x - c.x, dy = p.y - c.y;
    if (hypot(dx, dy) < self.dpadR * 0.25) return 0;
    double a = atan2(-dy, dx) * 180 / M_PI; uint64_t m = 0;
    if (a > -67.5 && a < 67.5) m |= 1ull << B_RIGHT;
    if (a > 22.5 && a < 157.5) m |= 1ull << B_UP;
    if (a > 112.5 || a < -112.5) m |= 1ull << B_LEFT;
    if (a < -22.5 && a > -157.5) m |= 1ull << B_DOWN;
    return m;
}
- (CGPoint)knobOffset:(int)i {   // knob offset from the stick centre (clamped to the stick radius)
    if (!_stick[i]) return CGPointZero;
    CGPoint h = [self stickCentre:i]; CGFloat dx = _stickNow[i].x - h.x, dy = _stickNow[i].y - h.y, d = hypot(dx, dy), R = [self stickR:i];
    if (d > R) { dx *= R / d; dy *= R / d; }
    return CGPointMake(dx, dy);
}

// ---- Touch ----
- (void)recompute {
    uint64_t face = 0; for (UITouch *t in _faceOf) face |= [_faceOf objectForKey:t].unsignedLongLongValue;
    BOOL drift = (face >> KT_DRIFT_BIT) & 1, item = (face >> KT_ITEM_BIT) & 1;   // kart: drift holds A and R, item A and L
    if (drift) face = (face & ~(1ull << KT_DRIFT_BIT)) | 1ull << B_A | 1ull << B_R;
    if (item) face = (face & ~(1ull << KT_ITEM_BIT)) | 1ull << B_A | 1ull << B_L;
    BOOL driftChanged = drift != _driftOn; _driftOn = drift;
    uint64_t btn = 0, dpad = 0; BOOL swap = NO;
    for (UITouch *t in _owner) { uint64_t v = [_owner objectForKey:t].unsignedLongLongValue; int c = (int)(v & 0xff);
        if (c == C_BTN) btn |= 1ull << (v >> 8);
        else if (c == C_DPAD) dpad |= [self dpadAt:[t locationInView:self]];
        else if (c == C_SWAP) swap = YES; }
    btn |= _pulseMask;   // the kart style's gestures: the two-finger tap's L + R, a tap's A, a swipe's D-pad, a long press's B (pulse:)
    int32_t ax[4] = {0};
    for (int i = 0; i < 2; i++) {
        CGPoint o = [self knobOffset:i]; CGFloat R = [self stickR:i], d = hypot(o.x, o.y), dz = R * K_DEAD;
        if (d <= dz) continue;
        CGFloat m = fmin((d - dz) / (R * K_FULL - dz), 1) / d;   // outside the dead zone: 0 rising to full at the full-tilt radius
        ax[i * 2] = (int32_t)lrint(o.x * m * 32767); ax[i * 2 + 1] = (int32_t)lrint(-o.y * m * 32767);   // host: up is positive; rounded so full tilt is exactly 32767
    }
    if (_pulseLy) ax[1] = _pulseLy;   // a gesture holding the left stick (the backward flick's down)
    BOOL changed = face != _faceBits || dpad != _dpadBits || btn != _btnBits || swap != _swapHeld || driftChanged;
    uint64_t pressed = (face | dpad | btn) & ~(_faceBits | _dpadBits | _btnBits);
    unsigned gripping = (_stick[0] ? 1u : 0) | (_stick[1] ? 2u : 0);
    if (pressed || (swap && !_swapHeld) || (gripping & ~_hapticSticks)) {
        [_touchFeedback impactOccurredWithIntensity:0.6]; [_touchFeedback prepare];
    }
    _hapticSticks = gripping;
    _faceBits = face; _dpadBits = dpad; _btnBits = btn; _swapHeld = swap;
    pthread_mutex_lock(&g_mu);
    g_touch_btn = face | dpad | btn; g_touch_lx = ax[0]; g_touch_ly = ax[1]; g_touch_rx = ax[2]; g_touch_ry = ax[3];
    pthread_mutex_unlock(&g_mu);
    publish();
    BOOL stick = _stick[0] != nil;   // only the left stick is drawn: the right one needs no refresh
    if (changed || stick || _stickShown) [self refresh];   // also refresh on the stick release so the knob returns to the centre
    _stickShown = stick;
}
// Touches no control takes (all of them while a physical controller is connected) go to the game's touch screen, normalized on the 16:9 picture that front_ios.m
// centres in the screen: Super Mario Galaxy's pointer in handheld mode (profile op_mode). The host reports them only in handheld mode, as on the Switch (hle_hid.c touch_read)
- (void)pushGame {
    CGRect b = self.bounds; CGFloat w = b.size.width, h = b.size.height;
    if (w <= 0 || h <= 0) return;
    if (w / h > 16.0 / 9.0) w = h * 16.0 / 9.0; else h = w * 9.0 / 16.0;
    CGFloat x0 = (b.size.width - w) / 2, y0 = (b.size.height - h) / 2;
    dm_touch t[16]; int n = 0;
    for (int i = 0; i < 16; i++) if (_game[i]) {
        CGPoint p = [_game[i] locationInView:self];
        t[n++] = (dm_touch){(uint32_t)i, (float)fmin(fmax((p.x - x0) / w, 0), 0.999), (float)fmin(fmax((p.y - y0) / h, 0), 0.999)};
    }
    dm_touch_set(t, n);
}
- (BOOL)gameBegin:(UITouch *)t {
    for (int i = 0; i < 16; i++) if (!_game[i]) { _game[i] = t; [_owner setObject:@(C_GAME | (uint64_t)i << 8) forKey:t]; return YES; }
    return NO;
}
- (void)touchesBegan:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e {
    BOOL game = NO;
    for (UITouch *t in ts) {
        if (_autoHidden && g_kart && !_kartTouch) {   // the kart controls hidden by the rule or by hand: gestures stand in for the buttons (gestureEnd / touchesMoved), since the game takes no touch
            CGPoint p = [t locationInView:self]; [_owner setObject:@(C_GESTURE) forKey:t]; [_gStart setObject:[NSValue valueWithCGPoint:p] forKey:t]; [_gTime setObject:@(CACurrentMediaTime()) forKey:t]; continue; }
        if (_padOff || _autoHidden) { if (_autoHidden || !g_kart || _kartTouch) game |= [self gameBegin:t]; continue; }   // controls hidden: every touch goes to the game, except the kart style's under a controller (Mario Kart opens menus on a tap) unless Touch on menus is on
        CGPoint p = [t locationInView:self]; int hit = _tap ? -1 : [self btnAt:p];
        if (hit >= 0) { [_owner setObject:@(C_BTN | (uint64_t)hit << 8) forKey:t]; continue; }
        if ([self inSwap:p]) { [_owner setObject:@(C_SWAP) forKey:t]; continue; }
        if (_tap) { game |= [self gameBegin:t]; continue; }
        // diamond, D-pad, left stick: take the one with the smallest distance / grab radius, if it is <= 1
        CGFloat best = 1; int kind = C_NONE, idx = 0;
        CGFloat f = dist(p, self.faceCenter) / (self.faceGap + self.faceR * 1.6);
        if (g_kart) f = [self kartFaceAt:p grab:1.25] ? 0 : INFINITY;   // pedals, drift, look back
        else if (g_mobile) { f = INFINITY; for (int b = B_A; b <= B_Y; b++) f = fmin(f, dist(p, [self facePos:b]) / ([self keyR:b] * 1.6)); }   // the arc: the nearest key
        if (f <= best) { best = f; kind = C_FACE; }
        if (_full && !g_kart) { CGFloat d = dist(p, self.dpadCenter) / (self.dpadR * K_DPAD_GRAB); if (d < best) { best = d; kind = C_DPAD; } }
        if (!_stick[0] && !g_mobile) { CGFloat s = dist(p, self.stickHome) / ([self stickR:0] * K_STICK_GRAB); if (s < best) { best = s; kind = C_STICK; } }
        if (kind == C_NONE && g_mobile && !_stick[0] && [self inStickZone:p]) { kind = C_STICK; _lCentre = p; }   // the floating stick: centred under the thumb
        if (kind == C_NONE && _full && !g_kart && !_stick[1] && [self inRightArea:p]) { kind = C_STICK; idx = 1; _rCentre = p; }   // the right stick: centred where the touch lands
        if (kind == C_FACE) { [_owner setObject:@(C_FACE) forKey:t]; [_faceOf setObject:@(g_kart ? [self kartFaceAt:p grab:1.25] : [self faceAt:p]) forKey:t]; }
        else if (kind == C_DPAD) [_owner setObject:@(C_DPAD) forKey:t];
        else if (kind == C_STICK) { [_owner setObject:@(C_STICK | (uint64_t)idx << 8) forKey:t]; _stick[idx] = t; _stickNow[idx] = p; }
        else if (!g_kart || _kartTouch) game |= [self gameBegin:t];   // the kart style: a touch on no control does nothing, unless Touch on menus is on
        else [_owner setObject:@(C_EMPTY) forKey:t];
    }
    if (game) [self pushGame];
    if (g_kart) [self lrCheck];
    [self recompute];
}
- (void)touchesMoved:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e {
    BOOL game = NO;
    for (UITouch *t in ts) {
        uint64_t v = [_owner objectForKey:t].unsignedLongLongValue; int c = (int)(v & 0xff); CGPoint p = [t locationInView:self];
        if (c == C_GESTURE) {   // a swipe of 40 points: one D-pad press in its direction, once per touch
            if ([_gFired containsObject:t]) continue;
            CGPoint s = [[_gStart objectForKey:t] CGPointValue]; CGFloat dx = p.x - s.x, dy = p.y - s.y;
            if (hypot(dx, dy) < 40) continue;
            [_gFired addObject:t]; [self pulse:1ull << (fabs(dx) > fabs(dy) ? (dx > 0 ? B_RIGHT : B_LEFT) : (dy > 0 ? B_DOWN : B_UP)) ms:120]; continue; }
        if (c == C_FACE) { uint64_t f = [self faceAt:p], was = [_faceOf objectForKey:t].unsignedLongLongValue;
            if (g_kart && !f && (was & (1ull << B_A | 1ull << KT_DRIFT_BIT | 1ull << KT_ITEM_BIT))) f = 1ull << B_A;   // between gas, drift and item: keep the gas
            if (g_kart && (was & 1ull << KT_ITEM_BIT) && (f & 1ull << KT_DRIFT_BIT)) f |= 1ull << KT_ITEM_BIT;   // an item held from item stays held on to drift (dragging it while drifting); back on gas it lets go
            [_faceOf setObject:@(f) forKey:t]; }
        else if (c == C_STICK) { _stickNow[v >> 8] = p;
            if ((v >> 8) == 1) { CGFloat d = dist(p, _rCentre), R = [self stickR:1];   // the right stick's centre follows a finger past its radius, so turning back responds at once
                if (d > R) _rCentre = CGPointMake(p.x - (p.x - _rCentre.x) * R / d, p.y - (p.y - _rCentre.y) * R / d); } }   // the floating left stick stays where its touch landed: past the ring the knob stops at the edge (knobOffset), at full tilt
        else if (c == C_GAME) game = YES;
    }
    if (game) [self pushGame];
    [self recompute];
}
- (void)endTouches:(NSSet<UITouch *> *)ts tapped:(BOOL)ended {
    BOOL swap = NO, game = NO;
    for (UITouch *t in ts) {
        uint64_t v = [_owner objectForKey:t].unsignedLongLongValue;
        if (ended && (v & 0xff) == C_SWAP && [self inSwap:[t locationInView:self]]) swap = YES;   // layout button: counts only when released on the button
        if ((v & 0xff) == C_GAME && (v >> 8) < 16) { _game[v >> 8] = nil; game = YES; }
        if ((v & 0xff) == C_GESTURE) {   // a touch that did not swipe: a tap (under 0.5 s) presses A, a long press B; a cancelled touch presses nothing
            if (ended && ![_gFired containsObject:t]) [self pulse:1ull << (CACurrentMediaTime() - [_gTime objectForKey:t].doubleValue < 0.5 ? B_A : B_B) ms:120];
            [_gStart removeObjectForKey:t]; [_gTime removeObjectForKey:t]; [_gFired removeObject:t]; }
        [_owner removeObjectForKey:t]; [_faceOf removeObjectForKey:t]; for (int i = 0; i < 2; i++) if (t == _stick[i]) _stick[i] = nil;
    }
    if (game) [self pushGame];
    if (g_kart) [self lrCheck];
    [self recompute];
    if (swap) [self nextLayout];
}
- (void)touchesEnded:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e { [self endTouches:ts tapped:YES]; }
- (void)touchesCancelled:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e { [self endTouches:ts tapped:NO]; }
// On-screen controls in races only (DM_KART_PAD auto): the draws of the last frame, smoothed, say whether the game draws its world. Hysteresis (hide under 500, show over 800) and 0.8 s of
// agreement keep a loading screen's black frames or a menu's busy transition from flickering the controls
- (void)autoTick {
    double d = dm_world_draws(); _drawsEma = _drawsEma * 0.7 + d * 0.3;
    int hint = dm_pad_hint();   // the files the game opened decide, on each change (the profile's pad_show_files / pad_hide_files); the draw count only before the first of them (boot, the title demo)
    { static uint32_t last; static int tick; uint32_t r = dm_touch_reads();
      if (++tick % 30 == 0) { LOG("front end: pad signal: %.0f draws a frame, %.1f touch reads a second, file hint %d, controls %s", _drawsEma, (r - last) / 3.0, hint, _autoHidden ? "hidden" : "shown"); last = r; } }
    if (hint != _lastHint) { _lastHint = hint; if (hint) { BOOL hide = hint == 2; if (hide != _autoHidden) [self setControlsHidden:hide why:hide ? "the game opened a menu's files: touches go to the game" : "the game opened its play's files"]; return; } }
    if (_lastHint) return;   // a hint has decided; the player's two-finger double tap changes it by hand (lrCheck)
    BOOL flip = _autoHidden ? _drawsEma > 800 : _drawsEma < 500;
    if (!flip) { _autoCount = 0; return; }
    if (++_autoCount < 8) return;
    char why[96]; snprintf(why, sizeof why, "%.0f draws a frame: %s", _drawsEma, _autoHidden ? "the game's world" : "a menu, touches go to the game");
    [self setControlsHidden:!_autoHidden why:why];
}
- (void)setControlsHidden:(BOOL)hide why:(const char *)why {
    _autoHidden = hide; _autoCount = 0; _controls.hidden = _padOff || hide; atomic_store(&g_pad_shown, !_controls.hidden); [self reset];
    LOG("front end: on-screen controls %s (%s)", hide ? "hidden" : "shown", why);
}
// The kart style's two-finger tap: two touches on no control (the game's touch screen or empty) at once press L and R together for 150 ms, once per such pair, for the title screen's
// "Press L + R" and the controller screens that ask for it; a single stray touch presses nothing (in a race L and R would be a drift and an item)
- (void)lrCheck {
    NSMutableArray<UITouch *> *free = [NSMutableArray array];
    for (UITouch *t in _owner) { int c = (int)([_owner objectForKey:t].unsignedLongLongValue & 0xff); if (c == C_GAME || c == C_EMPTY || c == C_GESTURE) [free addObject:t]; }
    if (free.count < 2) { _lrArmed = NO; return; }
    for (UITouch *t in free) [_gFired addObject:t];   // a pair is no tap or swipe
    if (_lrArmed) return;
    _lrArmed = YES; [_touchFeedback impactOccurred]; [self pulse:1ull << B_L | 1ull << B_R ms:150];
    double now = CACurrentMediaTime();   // a second two-finger tap within 0.45 s: the controls shown or hidden by hand (the automatic rule takes over again at the game's next screen change)
    if (now - _lrLast < 0.45) { _lrLast = 0; [self setControlsHidden:!_autoHidden why:"a two-finger double tap"]; } else _lrLast = now;
}
// Buttons held for a moment by a gesture: added to the published mask now, taken out after ms (an overlapping pulse of the same buttons ends with the later one)
- (void)pulse:(uint64_t)mask ms:(int)ms { [self pulse:mask ly:0 ms:ms]; }
- (void)pulse:(uint64_t)mask ly:(int32_t)ly ms:(int)ms {
    _pulseMask |= mask; if (ly) _pulseLy = ly; [self recompute];
    __weak typeof(self) w = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, ms * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ typeof(self) s = w; if (s) { s->_pulseMask &= ~mask; if (ly) s->_pulseLy = 0; [s recompute]; } });
}
- (void)reset { [_owner removeAllObjects]; [_faceOf removeAllObjects]; [_gStart removeAllObjects]; [_gTime removeAllObjects]; [_gFired removeAllObjects]; _stick[0] = _stick[1] = nil; for (int i = 0; i < 16; i++) _game[i] = nil; [self pushGame]; [self recompute]; }

// ---- Shapes ----
static CGPathRef circlePath(CGPoint c, CGFloat r) { return CGPathCreateWithEllipseInRect(CGRectMake(c.x - r, c.y - r, 2 * r, 2 * r), NULL); }
static CGPathRef dropPath(CGPoint c, CGFloat r, CGFloat tipAngle, CGFloat round) {   // teardrop: circle + two tangents meeting at the tip, tip slightly rounded
    CGFloat d = r * K_DROP_TIP, th = acos(r / d);
    CGPoint tip = CGPointMake(c.x + d * cos(tipAngle), c.y + d * sin(tipAngle));
    CGPoint p1 = CGPointMake(c.x + r * cos(tipAngle + th), c.y + r * sin(tipAngle + th)), p2 = CGPointMake(c.x + r * cos(tipAngle - th), c.y + r * sin(tipAngle - th));
    CGMutablePathRef p = CGPathCreateMutable();
    CGPathMoveToPoint(p, NULL, p2.x, p2.y);
    CGPathAddArcToPoint(p, NULL, tip.x, tip.y, p1.x, p1.y, round);
    CGPathAddArc(p, NULL, c.x, c.y, r, tipAngle + th, tipAngle - th + 2 * M_PI, false);
    CGPathCloseSubpath(p); return p;
}
static CGPathRef armPath(CGPoint c, CGFloat R, CGFloat w, CGFloat in, CGFloat angle, CGFloat round) {   // one D-pad arm: an upward pentagon (tip toward the centre) rotated by angle around the centre
    CGPoint v[5] = {{-w, -R}, {w, -R}, {w, -(in + w)}, {0, -in}, {-w, -(in + w)}};
    CGFloat cs = cos(angle), sn = sin(angle);
    for (int i = 0; i < 5; i++) v[i] = CGPointMake(c.x + v[i].x * cs - v[i].y * sn, c.y + v[i].x * sn + v[i].y * cs);
    CGMutablePathRef p = CGPathCreateMutable();
    CGPathMoveToPoint(p, NULL, (v[4].x + v[0].x) / 2, (v[4].y + v[0].y) / 2);
    for (int i = 0; i < 5; i++) CGPathAddArcToPoint(p, NULL, v[i].x, v[i].y, v[(i + 1) % 5].x, v[(i + 1) % 5].y, round);
    CGPathCloseSubpath(p); return p;
}
static void setPath(CAShapeLayer *l, CGPathRef p) { l.path = p; l.shadowPath = p; CGPathRelease(p); }
static void placeLabel(CATextLayer *t, CGPoint c, CGFloat fs) {
    CTFontRef f = CTFontCreateUIFontForLanguage(kCTFontUIFontEmphasizedSystem, fs, NULL);
    t.font = f; t.fontSize = fs;
    CGFloat h = CTFontGetAscent(f) + CTFontGetDescent(f) + CTFontGetLeading(f), w = fs * 3;
    t.frame = CGRectMake(c.x - w / 2, c.y - h / 2, w, h);
    CFRelease(f);
}

- (void)layoutSubviews {
    [super layoutSubviews];
    UIWindowScene *ws = self.window.windowScene; if (ws) atomic_store(&g_iface_orient, (int)ws.effectiveGeometry.interfaceOrientation);
    CGFloat u = self.u;
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    _controls.frame = self.layer.bounds;
    for (int b = B_A; b <= B_Y; b++) { CGPoint c = [self facePos:b]; CGFloat r = [self keyR:b];
        setPath(_key[b], circlePath(c, r)); placeLabel(_label[b], c, g_sinnoh ? r * 0.42 : 20 * u * r / self.faceR);   // sinnoh: the letter on the centre button
        if (_cap[b]) ball_paths(_cap[b], _band[b], _hub[b], c, r); }
    for (int i = 0; i < (int)(sizeof k_btns / sizeof *k_btns); i++) { int b = k_btns[i];
        if (isDrop(b) && g_mobile) {
            CGRect rc = [self dropRect:b];
            setPath(_key[b], CGPathCreateWithRoundedRect(rc, rc.size.height / 2, rc.size.height / 2, NULL)); placeLabel(_label[b], [self dropCenter:b], 15 * u);
        } else if (isDrop(b)) {
            BOOL right = b == B_ZR || b == B_R; CGPoint c = [self dropCenter:b];
            setPath(_key[b], dropPath(c, [self dropR:b], right ? -M_PI_4 : -3 * M_PI_4, 4 * u)); placeLabel(_label[b], c, 16 * u);   // tip toward the near top corner
        } else if (isClick(b)) {
            CGPoint c = [self clickCenter:b]; setPath(_key[b], circlePath(c, K_CLICK_R * u)); placeLabel(_label[b], c, 13 * u);
        } else {
            CGRect rc = [self pillRect:b];
            setPath(_key[b], CGPathCreateWithRoundedRect(rc, rc.size.height / 2, rc.size.height / 2, NULL)); placeLabel(_label[b], CGPointMake(CGRectGetMidX(rc), CGRectGetMidY(rc)), 18 * u);
        }
    }
    static const struct { int b; CGFloat angle; } arms[] = {{B_UP, 0}, {B_RIGHT, M_PI_2}, {B_DOWN, M_PI}, {B_LEFT, -M_PI_2}};   // the same arm in 90° steps
    for (int i = 0; i < 4; i++) setPath(_key[arms[i].b], armPath(self.dpadCenter, self.dpadR, (g_mobile ? M_ARM_W : K_ARM_W) * u, (g_mobile ? M_ARM_IN : K_ARM_IN) * u, arms[i].angle, (g_mobile ? 4 : 6) * u));
    CGPoint sc = self.swapCenter; setPath(_swap, circlePath(sc, K_SWAP_R * u)); placeLabel(_swapLabel, sc, 12 * u);
    setPath(_ring, circlePath(self.stickHome, [self stickR:0]));
    CGFloat k = K_KNOB_R * u; _knob.bounds = CGRectMake(0, 0, 2 * k, 2 * k);
    setPath(_knob, circlePath(CGPointMake(k, k), k));
    CAShapeLayer *in = (CAShapeLayer *)_knob.sublayers.firstObject; CGPathRef ip = circlePath(CGPointMake(k, k), k * 0.62);
    in.frame = _knob.bounds; in.path = ip; CGPathRelease(ip);
    if (_cap[B_N]) ball_paths(_cap[B_N], _band[B_N], _hub[B_N], CGPointMake(k, k), k);
    if (g_kart) [self layoutKart];
    [CATransaction commit];
    [self refresh];
}
static CGPathRef pedalPath(CGRect r, CGFloat in, CGFloat round) {   // a pedal: a rectangle whose bottom edge is in narrower on each side, corners rounded
    CGPoint v[4] = {{CGRectGetMinX(r), CGRectGetMinY(r)}, {CGRectGetMaxX(r), CGRectGetMinY(r)}, {CGRectGetMaxX(r) - in, CGRectGetMaxY(r)}, {CGRectGetMinX(r) + in, CGRectGetMaxY(r)}};
    CGMutablePathRef p = CGPathCreateMutable();
    CGPathMoveToPoint(p, NULL, (v[3].x + v[0].x) / 2, (v[3].y + v[0].y) / 2);
    for (int i = 0; i < 4; i++) CGPathAddArcToPoint(p, NULL, v[i].x, v[i].y, v[(i + 1) % 4].x, v[(i + 1) % 4].y, round);
    CGPathCloseSubpath(p); return p;
}
static void grooves(CAShapeLayer *l, CGRect r, const CGFloat *at, int n, CGFloat inset, CGFloat w) {   // horizontal grip lines at fractions of the pedal's height
    CGMutablePathRef p = CGPathCreateMutable();
    for (int i = 0; i < n; i++) { CGFloat y = CGRectGetMinY(r) + r.size.height * at[i];
        CGPathMoveToPoint(p, NULL, CGRectGetMinX(r) + inset, y); CGPathAddLineToPoint(p, NULL, CGRectGetMaxX(r) - inset, y); }
    l.path = p; l.lineWidth = w; CGPathRelease(p);
}
static void placeCaption(CATextLayer *t, CGPoint c, CGFloat fs) { placeLabel(t, c, fs); CGRect f = t.frame; t.frame = CGRectInset(f, -fs * 3, 0); }   // wide enough for BRAKE
- (void)layoutKart {   // pad_style kart: the pedals, drift, item and look back over the mobile style's shapes
    CGFloat u = self.u, fs = KT_CAPTION * u;
    CGRect gas = self.gasRect, brake = self.brakeRect;
    setPath(_key[B_A], pedalPath(gas, KT_PEDAL_IN * u, 8 * u)); placeLabel(_label[B_A], CGPointMake(CGRectGetMidX(gas), CGRectGetMidY(gas)), 20 * u);
    setPath(_key[B_B], pedalPath(brake, KT_PEDAL_IN * u, 8 * u)); placeLabel(_label[B_B], CGPointMake(CGRectGetMidX(brake), CGRectGetMidY(brake)), 18 * u);
    static const CGFloat gasAt[] = {0.18, 0.34, 0.68, 0.84}, brakeAt[] = {0.18, 0.82};
    grooves(_groove[0], gas, gasAt, 4, 18 * u, 4 * u); grooves(_groove[1], brake, brakeAt, 2, 16 * u, 4 * u);
    CGPoint back = self.backCentre; CGFloat b = KT_BACK_R * u / 27; setPath(_key[B_X], circlePath(back, KT_BACK_R * u));   // the mirror drawn for a radius of 27
    CGMutablePathRef mp = CGPathCreateMutable();
    CGPathAddRoundedRect(mp, NULL, CGRectMake(back.x - 15.5 * b, back.y - 6 * b, 31 * b, 15.5 * b), 6.5 * b, 6.5 * b);
    CGPathMoveToPoint(mp, NULL, back.x, back.y - 6 * b); CGPathAddLineToPoint(mp, NULL, back.x, back.y - 12 * b);   // its stem
    CGPathMoveToPoint(mp, NULL, back.x - 9.5 * b, back.y + 5.5 * b); CGPathAddLineToPoint(mp, NULL, back.x - 4.5 * b, back.y - 2 * b);   // the glass's glints
    CGPathMoveToPoint(mp, NULL, back.x - 4 * b, back.y + 6 * b); CGPathAddLineToPoint(mp, NULL, back.x, back.y + 0.5 * b);
    _backIcon.path = mp; CGPathRelease(mp); _backIcon.lineWidth = 2.5 * b;
    CGPoint item = self.itemCentre; CGFloat s = KT_ITEM_S * u;
    CGAffineTransform tilt = CGAffineTransformTranslate(CGAffineTransformRotate(CGAffineTransformMakeTranslation(item.x, item.y), KT_ITEM_TILT), -item.x, -item.y);
    setPath(_key[B_L], CGPathCreateWithRoundedRect(around(item, s, s), 14 * u, 14 * u, &tilt)); placeLabel(_label[B_L], item, 34 * u);
    CGPoint d = self.driftCentre; CGFloat r = KT_DRIFT_R * u, k = r / 46;   // the tire marks drawn for a radius of 46
    setPath(_drift, circlePath(d, r));
    CGMutablePathRef m = CGPathCreateMutable();
    CGPathMoveToPoint(m, NULL, d.x - 26 * k, d.y + 20 * k); CGPathAddQuadCurveToPoint(m, NULL, d.x - 20 * k, d.y - 14 * k, d.x + 18 * k, d.y - 22 * k);
    CGPathMoveToPoint(m, NULL, d.x - 13 * k, d.y + 26 * k); CGPathAddQuadCurveToPoint(m, NULL, d.x - 6 * k, d.y - 4 * k, d.x + 26 * k, d.y - 10 * k);
    _driftIcon.path = m; CGPathRelease(m); _driftIcon.lineWidth = 6 * k; _driftIcon.lineDashPattern = @[@(4 * k), @(3 * k)];
    _ring.lineWidth = 3 * u;
    [self layoutMushroom];
    CGFloat below = fs * 1.2;
    placeCaption(_caption[0], CGPointMake(CGRectGetMidX(gas), CGRectGetMaxY(gas) + below), fs);
    placeCaption(_caption[1], CGPointMake(CGRectGetMidX(brake), CGRectGetMaxY(brake) + below), fs);
    placeCaption(_caption[2], CGPointMake(d.x, d.y + r + below), fs);
    placeCaption(_caption[3], CGPointMake(item.x, item.y + s * 0.6 + below), fs);
    if (g_world) {   // rewind: two triangles pointing back; the map: a sheet folded in three, drawn for look back's radius of 27
        CGPoint w = self.rewindCentre, a = self.mapCentre;
        setPath(_key[B_DOWN], circlePath(w, KT_BACK_R * u)); setPath(_key[B_Y], circlePath(a, KT_BACK_R * u));
        CGMutablePathRef rw = CGPathCreateMutable();
        for (int i = 0; i < 2; i++) { CGFloat x = w.x + (i ? 11 : -1) * b;
            CGPathMoveToPoint(rw, NULL, x, w.y - 9 * b); CGPathAddLineToPoint(rw, NULL, x - 11 * b, w.y); CGPathAddLineToPoint(rw, NULL, x, w.y + 9 * b); CGPathCloseSubpath(rw); }
        _worldIcon[0].path = rw; CGPathRelease(rw); _worldIcon[0].lineWidth = 2.5 * b;
        CGMutablePathRef mq = CGPathCreateMutable();
        CGPathMoveToPoint(mq, NULL, a.x - 14 * b, a.y - 8 * b); CGPathAddLineToPoint(mq, NULL, a.x - 5 * b, a.y - 11 * b); CGPathAddLineToPoint(mq, NULL, a.x + 5 * b, a.y - 8 * b); CGPathAddLineToPoint(mq, NULL, a.x + 14 * b, a.y - 11 * b);
        CGPathAddLineToPoint(mq, NULL, a.x + 14 * b, a.y + 8 * b); CGPathAddLineToPoint(mq, NULL, a.x + 5 * b, a.y + 11 * b); CGPathAddLineToPoint(mq, NULL, a.x - 5 * b, a.y + 8 * b); CGPathAddLineToPoint(mq, NULL, a.x - 14 * b, a.y + 11 * b); CGPathCloseSubpath(mq);
        CGPathMoveToPoint(mq, NULL, a.x - 5 * b, a.y - 11 * b); CGPathAddLineToPoint(mq, NULL, a.x - 5 * b, a.y + 8 * b);
        CGPathMoveToPoint(mq, NULL, a.x + 5 * b, a.y - 8 * b); CGPathAddLineToPoint(mq, NULL, a.x + 5 * b, a.y + 11 * b);
        _worldIcon[1].path = mq; CGPathRelease(mq); _worldIcon[1].lineWidth = 2.5 * b;
        placeCaption(_caption[4], CGPointMake(w.x, w.y + KT_BACK_R * u + below), fs); placeCaption(_caption[5], CGPointMake(a.x, a.y + KT_BACK_R * u + below), fs);
    }
}
- (void)layoutMushroom {   // the kart knob: a spotted mushroom cap over a stem with two eyes, drawn for a knob radius of 25, in the knob's own bounds
    CGFloat k = K_KNOB_R * self.u, s = k / 25;
    CGAffineTransform cap = CGAffineTransformScale(CGAffineTransformMakeTranslation(k, k + 4 * s), 1, 22.0 / 24);
    CGMutablePathRef p = CGPathCreateMutable(); CGPathMoveToPoint(p, &cap, -24 * s, 0); CGPathAddArc(p, &cap, 0, 0, 24 * s, M_PI, 0, false); CGPathCloseSubpath(p);
    _knob.path = p; CGPathRelease(p); _knob.lineWidth = 2 * s; _knob.lineJoin = kCALineJoinRound;
    static const CGFloat spots[3][3] = {{-10, -6, 5}, {10, -8, 4}, {0, -14, 3}}, eyes[2][2] = {{-5, 11}, {5, 11}};
    p = CGPathCreateMutable(); for (int i = 0; i < 3; i++) CGPathAddEllipseInRect(p, NULL, CGRectMake(k + (spots[i][0] - spots[i][2]) * s, k + (spots[i][1] - spots[i][2]) * s, 2 * spots[i][2] * s, 2 * spots[i][2] * s));
    _mush[0].path = p; CGPathRelease(p);
    p = CGPathCreateMutable(); CGPathAddRoundedRect(p, NULL, CGRectMake(k - 12 * s, k + 4 * s, 24 * s, 16 * s), 7 * s, 7 * s);
    _mush[1].path = p; CGPathRelease(p); _mush[1].lineWidth = 2 * s;
    p = CGPathCreateMutable(); for (int i = 0; i < 2; i++) CGPathAddEllipseInRect(p, NULL, CGRectMake(k + (eyes[i][0] - 1.8) * s, k + (eyes[i][1] - 1.8) * s, 3.6 * s, 3.6 * s));
    _mush[2].path = p; CGPathRelease(p);
    for (int i = 0; i < 3; i++) _mush[i].frame = _knob.bounds;
}
- (void)safeAreaInsetsDidChange { [super safeAreaInsetsDidChange]; [self setNeedsLayout]; }
- (void)refresh {   // pressed state → fill, sticks → knob position
    uint64_t all = _faceBits | _dpadBits | _btnBits;
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    for (int b = 0; b < B_N; b++) { BOOL on = (all >> b) & 1;
        _key[b].fillColor = (on ? c_on : c_idle)[b].CGColor; _label[b].foregroundColor = (on ? c_textOn : c_text)[b].CGColor;
        if (_cap[b]) _cap[b].fillColor = (on ? c_capOn : c_cap).CGColor; }
    if (_drift) _drift.fillColor = (_driftOn ? k_on : k_idle).CGColor;
    _swap.fillColor = (_swapHeld ? c_on : c_idle)[P_SWAP].CGColor; _swapLabel.foregroundColor = (_swapHeld ? c_textOn : c_text)[P_SWAP].CGColor;
    CGPoint h = [self stickCentre:0], o = [self knobOffset:0];
    if (g_mobile) setPath(_ring, circlePath(h, [self stickR:0]));   // the floating stick's ring goes where the thumb landed
    _knob.position = CGPointMake(h.x + o.x, h.y + o.y); _knob.fillColor = (_stick[0] ? c_on : c_idle)[P_KNOB].CGColor;
    if (_cap[B_N]) _cap[B_N].fillColor = (_stick[0] ? c_capOn : c_cap).CGColor;
    [CATransaction commit];
}

// ---- Physical controllers ----
// Each controller with an extended gamepad profile is a player of its own, as on the Mac (front_mac.m): it holds a slot (pad_slots.h: player 1 first, a reconnected controller
// gets its player back) and goes to dm_pad_set_player, and hle_hid.c reports player n on its own npad while the slot is held (dm_pad_players). Player 1's controller is ORed
// with the touch gamepad; a one-player game that supports only No1 / Handheld still sees every controller as player 1 (hle_hid.c). Each player has its controller's rumble and
// gyro; the phone's gyro is player 1's. With DM_PAD_MERGE=1 every controller is player 1, as before (the last one moved wins)
static pad_slots g_slots;
static GCController *g_held[DM_PLAYERS];   // the controller of each slot, kept alive while it holds it (the slot table keys on its pointer)
static int g_merge;
static int32_t axis(float v) { return (int32_t)(fmaxf(-1.f, fminf(1.f, v)) * 32767); }
static void read_pad(GCExtendedGamepad *g) {
    int p = g_merge ? 0 : pad_slot_of(&g_slots, (__bridge const void *)g.controller); if (p < 0) return;
    dm_haptics_apple_controller(p, g.controller);
    _Static_assert(DM_BTN_A == 1u << B_A && DM_BTN_B == 1u << B_B && DM_BTN_X == 1u << B_X && DM_BTN_Y == 1u << B_Y, "face button bits");
    uint64_t m = dm_pad_face(g);   // by position, a Nintendo pad by its labels
    #define K(btn, bit) if (btn.isPressed) m |= 1ull << bit
    K(g.leftShoulder, B_L); K(g.rightShoulder, B_R); K(g.leftTrigger, B_ZL); K(g.rightTrigger, B_ZR);
    K(g.buttonMenu, B_PLUS); if (g.buttonOptions) K(g.buttonOptions, B_MINUS);
    if (g.leftThumbstickButton) K(g.leftThumbstickButton, B_LS); if (g.rightThumbstickButton) K(g.rightThumbstickButton, B_RS);
    K(g.dpad.left, B_LEFT); K(g.dpad.up, B_UP); K(g.dpad.right, B_RIGHT); K(g.dpad.down, B_DOWN);
    #undef K
    dm_pad_set_player(p, m, axis(g.leftThumbstick.xAxis.value), axis(g.leftThumbstick.yAxis.value), axis(g.rightThumbstick.xAxis.value), axis(g.rightThumbstick.yAxis.value));
}
// Home and Capture: without this iOS takes them as system gestures (Home opens the Games overlay, Capture a screenshot); the app gives them no function
static void pad_keep_system_buttons(GCController *c) { for (NSString *b in @[GCInputButtonHome, GCInputButtonShare]) c.physicalInputProfile.buttons[b].preferredSystemGestureState = GCSystemGestureStateDisabled; }
static const char *pad_name(GCController *c) { return c.vendorName.UTF8String ?: "?"; }
static void npad_name(int p, char *out, size_t cap) { uint32_t id = dm_player_npad(p); if (id == 0x20) snprintf(out, cap, "handheld"); else snprintf(out, cap, "%u", id); }
static void pads_start(void) {
    const char *e = getenv("DM_PAD_MERGE"); g_merge = e && atoi(e);
    LOG("front end: %s", g_merge ? "every controller is player 1 (DM_PAD_MERGE)" : "each controller is a player of its own, the touch gamepad plays with player 1");
}
// Called at start and on every connect / disconnect (gone: the controller that was just removed, nil otherwise); returns whether a controller is in use
static BOOL pads_merged(GCController *gone) {
    if (gone) { gone.extendedGamepad.valueChangedHandler = nil; dm_motion_detach(gone, 0); }
    BOOL any = NO; int motion = 0;
    for (GCController *c in GCController.controllers) if (c != gone && c.extendedGamepad) {
        if (c.motion.hasRotationRate) motion = 1;
        any = YES; pad_keep_system_buttons(c); c.extendedGamepad.valueChangedHandler = ^(GCExtendedGamepad *g, GCControllerElement *el) { (void)el; read_pad(g); };
        dm_motion_attach(c, 0);   // every controller is player 1: the last one moved drives its six-axis sensor
        read_pad(c.extendedGamepad);
    }
    if (!any || !motion) dm_motion_clear(0);   // the phone's gyro (if on) takes over from its next sample
    if (!any) { dm_haptics_apple_controller(0, nil); dm_pad_set(0, 0, 0, 0, 0); }
    return any;
}
static BOOL pads_slotted(GCController *gone) {
    NSArray<GCController *> *now = GCController.controllers; char nb[16];
    for (int p = 0; p < DM_PLAYERS; p++) if (g_held[p] && (g_held[p] == gone || ![now containsObject:g_held[p]])) {
        npad_name(p, nb, sizeof nb); LOG("controller '%s' disconnected: player %d (npad %s) is free", pad_name(g_held[p]), p + 1, nb);
        g_held[p].extendedGamepad.valueChangedHandler = nil;
        dm_motion_detach(g_held[p], p);   // player 1's: the phone's gyro (if on) takes over from its next sample
        dm_haptics_apple_controller(p, nil);
        pad_slot_free(&g_slots, (__bridge const void *)g_held[p]); g_held[p] = nil;
        dm_pad_set_player(p, 0, 0, 0, 0, 0);   // nothing stays pressed
    }
    for (GCController *c in now) if (c.extendedGamepad && c != gone && pad_slot_of(&g_slots, (__bridge const void *)c) < 0) {
        int p = pad_slot_take(&g_slots, (__bridge const void *)c, pad_name(c));
        if (p < 0) { LOG("controller '%s' connected: all %d players are taken, not used", pad_name(c), DM_PLAYERS); continue; }
        g_held[p] = c; pad_keep_system_buttons(c);
        c.extendedGamepad.valueChangedHandler = ^(GCExtendedGamepad *g, GCControllerElement *el) { (void)el; read_pad(g); };
        dm_motion_attach(c, p);
        npad_name(p, nb, sizeof nb); LOG("controller '%s' connected: player %d (npad %s)%s", pad_name(c), p + 1, nb, c.motion.hasRotationRate ? ", with motion (gyro)" : "");
        read_pad(c.extendedGamepad);
    }
    dm_pad_players(pad_slot_mask(&g_slots));
    return pad_slot_mask(&g_slots) != 0;
}
- (void)padsChanged:(NSNotification *)note {
    GCController *c = note.object, *gone = [note.name isEqual:GCControllerDidDisconnectNotification] ? c : nil;
    if (c && (!c.extendedGamepad || g_merge)) LOG("controller %s: %s%s", gone ? "disconnected" : "connected", pad_name(c), c.extendedGamepad ? "" : " (no extended gamepad profile: not used)");
    BOOL any = g_merge ? pads_merged(gone) : pads_slotted(gone);
    dispatch_async(dispatch_get_main_queue(), ^{ self->_padOff = any; self->_controls.hidden = any || self->_autoHidden; atomic_store(&g_pad_shown, !self->_controls.hidden); [self reset]; });   // the touch gamepad hides while any controller is in use
}
@end

UIView *dm_gamepad_view(CGRect frame) { DmGamepad *v = [[DmGamepad alloc] initWithFrame:frame]; g_view = v; return v; }
void dm_gamepad_active(void) { dispatch_async(dispatch_get_main_queue(), ^{ for (GCController *c in GCController.controllers) dm_motion_rearm(c); }); }   // On become active: motion_apple.h
void dm_gamepad_reset(void) {   // On resign active: release everything (a key held while switching away and released in background gets no "release")
    dispatch_async(dispatch_get_main_queue(), ^{ [g_view reset]; });
    pthread_mutex_lock(&g_mu); g_shake_btn = 0; pthread_mutex_unlock(&g_mu); publish();
    if (g_merge) dm_pad_set(0, 0, 0, 0, 0);
    else for (int p = 0; p < DM_PLAYERS; p++) if (g_held[p]) dm_pad_set_player(p, 0, 0, 0, 0, 0);
}
