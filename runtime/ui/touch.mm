// On-screen controller and the Phone tab (runtime/ui/touch.h).
//
// Layout: a 1080-unit-tall reference over the whole screen, controls placed from the safe area's corners (the notch,
// the home indicator), sizes times Touch Size. Left: stick (fixed, or Floating: it appears where the thumb lands in the
// left part of the screen) with the d-pad above it and L3 beside; right: A/B/X/Y in the Xbox diamond, the right stick
// and R3; top: LB / LT and RB / RT in the corners, View / Menu in the middle with the gear (the menu's Phone tab).
// Buttons are SDL gamepad buttons by position, so the player's controller bindings apply (Xbox A = the bottom button).
//
// Threads: fingers arrive on the main thread (touch_handle_event), which owns the controls and tells the game
// (input_touch_set); the render thread draws a copy of their state inside the menu's ImGui frame (touch_overlay_draw).
#include "touch.h"

#include <SDL3/SDL.h>
#include <float.h>
#include <math.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <atomic>
#include <map>
#include <set>
#include <vector>

#include "imgui.h"
#include "option_rows.h"

#if defined(__APPLE__)
#include <TargetConditionals.h>
#endif
#if defined(__APPLE__) && TARGET_OS_IPHONE
#define TOUCH_PHONE 1
#else
#define TOUCH_PHONE 0
#endif
#if TOUCH_PHONE && defined(__OBJC__)
#import <UIKit/UIKit.h>
#endif

#include <unistd.h>

extern "C" {
#include "../input_bind.h"
#include "../paths.h"
#include "../settings.h"
#include "menu.h"
SDL_Window *ui_window(void);       // runtime/nvn/metal.m
bool menu_input_captured(void);    // menu.mm: the menu or a name entry has the input
void menu_open_tab(int id);        // menu.mm: opens the menu on that tab (main thread)
}

enum { MENU_TAB_PHONE = 0 };  // (menu.mm's tab id: the Video tab, "Phone" on iPhone)

static bool enabled(void) {
#if TOUCH_PHONE
    return true;
#else
    static int on = -1;  // LARECOMP_TOUCH=1 (test): the overlay on a desktop, the mouse as the finger
    if (on < 0) on = getenv("LARECOMP_TOUCH") && atoi(getenv("LARECOMP_TOUCH"));
    return on;
#endif
}

// ------------------------------------------------------------------ haptics (main thread)
#if TOUCH_PHONE && defined(__OBJC__)
static UIImpactFeedbackGenerator *g_tap_gen, *g_rumble_gen;
static void haptic_tap(void) {
    if (!g_settings.phone_vibration) return;
    if (!g_tap_gen) g_tap_gen = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [g_tap_gen impactOccurredWithIntensity:0.7];
    [g_tap_gen prepare];
}
static void haptic_rumble(float k) {
    if (!g_rumble_gen) g_rumble_gen = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [g_rumble_gen impactOccurredWithIntensity:k];
}
#else
static void haptic_tap(void) {}
static void haptic_rumble(float k) { (void)k; }
#endif

bool touch_rumble_wanted(void) { return TOUCH_PHONE && g_settings.phone_vibration; }

// The game's rumble holds a strength until changed (runtime/hle/input.c renews it every 100 ms): the phone's motor
// gives taps, so a held rumble becomes a tap at that strength every ~90 ms, a stronger one at once.
void touch_rumble(uint16_t lo, uint16_t hi) {
    static uint64_t last;
    static float last_k;
    float k = (lo > hi ? lo : hi) / 65535.0f;
    uint64_t now = SDL_GetTicks();
    if (k < 0.08f) { last_k = 0; return; }
    if (now - last < 90 && k <= last_k + 0.2f) return;
    last = now, last_k = k;
    haptic_rumble(k > 1 ? 1 : k);
}

// ------------------------------------------------------------------ controls
enum Kind { BUTTON, SHOULDER, TRIGGER, DPAD, STICK };
enum Icon { ICON_NONE, ICON_VIEW, ICON_MENU, ICON_GEAR };
enum Anchor { BL, BR, TL, TR, TC };

struct Control {
    Kind kind;
    int host = -1;          // SDL_GamepadButton / PADB_*TRIGGER (-1: none: the gear)
    float x = 0, y = 0;     // centre (pixels)
    float w = 0, h = 0;     // size (pixels; sticks: w = the base's diameter)
    float hit = 1.18f;      // hit area scale
    const char *label = "";
    ImU32 accent = IM_COL32(255, 255, 255, 255);
    bool colored = false;   // A / B / X / Y: coloured labels, presses slide between them
    Icon icon = ICON_NONE;
    bool left = false;      // sticks: the left one
    // state (main thread; copied for drawing)
    SDL_FingerID finger = 0;
    bool owned = false, pressed = false;
    bool dir[4] = {};       // d-pad: right, up, left, down
    float kx = 0, ky = 0;   // stick: the knob's offset from the centre (pixels)
    float hx = 0, hy = 0;   // stick: its home centre (a floating one moves to the thumb)
    // d-pad timing (main thread)
    uint64_t since[4] = {}, next_pulse[4] = {};
    bool pulse[4] = {};
};

static const ImU32 XBOX_GREEN = IM_COL32(92, 204, 51, 255), XBOX_RED = IM_COL32(237, 61, 54, 255),
                   XBOX_BLUE = IM_COL32(51, 133, 245, 255), XBOX_YELLOW = IM_COL32(255, 199, 38, 255);
static const int DPAD_HOST[4] = {SDL_GAMEPAD_BUTTON_DPAD_RIGHT, SDL_GAMEPAD_BUTTON_DPAD_UP, SDL_GAMEPAD_BUTTON_DPAD_LEFT,
                                 SDL_GAMEPAD_BUTTON_DPAD_DOWN};

static std::vector<Control> g_ctl;               // main thread
static std::map<SDL_FingerID, int> g_owner;      // finger -> control index
static std::set<SDL_FingerID> g_ignore;          // fingers ignored until they lift (the layout changed under them)
static float g_zone_x1, g_zone_y0;               // the floating stick's zone: left of x1, below y0
static bool g_shown;                              // main thread: the overlay is up
static std::atomic<bool> g_draw{false};           // render thread: draw it
static std::atomic<int> g_panel_w{0}, g_panel_h{0};
static std::atomic<bool> g_share_req{false};      // the Phone tab's Share Log (render thread) -> touch_frame (main)
static void share_logs(void);
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;  // g_snap
static std::vector<Control> g_snap;               // what the render thread draws

static void layout(int W, int H, SDL_Rect safe_pt, float density) {
    float sl = safe_pt.x * density, st = safe_pt.y * density;
    float sr = sl + safe_pt.w * density, sb = st + safe_pt.h * density;
    if (safe_pt.w <= 0 || safe_pt.h <= 0) sl = 0, st = 0, sr = (float)W, sb = (float)H;
    float u = H / 1080.0f, s = g_settings.touch_size / 100.0f;
    auto at = [&](Anchor a, float px, float py, float &x, float &y) {
        px *= u, py *= u;
        switch (a) {
        case BL: x = sl + px, y = sb - py; break;
        case BR: x = sr + px, y = sb - py; break;
        case TL: x = sl + px, y = st - py; break;
        case TR: x = sr + px, y = st - py; break;
        case TC: x = (sl + sr) / 2 + px, y = st - py; break;
        }
    };
    auto add = [&](Kind k, int host, Anchor a, float px, float py, float w, float h, const char *label = "") -> Control & {
        Control c;
        c.kind = k, c.host = host, c.label = label;
        at(a, px, py, c.x, c.y);
        c.w = w * u, c.h = h * u;
        c.hx = c.x, c.hy = c.y;
        g_ctl.push_back(c);
        return g_ctl.back();
    };
    g_ctl.clear();
    g_zone_x1 = sl + (sr - sl) * 0.40f, g_zone_y0 = sb - (sb - st) * 0.58f;
    Control &ls = add(STICK, -1, BL, 290 * s, 260 * s, 270 * s, 270 * s);
    ls.left = true, ls.hit = 1.25f;
    add(DPAD, -1, BL, 255 * s, 620 * s, 230 * s, 230 * s).hit = 1.12f;
    add(STICK, -1, BR, -575 * s, 175 * s, 184 * s, 184 * s).hit = 1.25f;
    float fb = 124 * s, sp = 108 * s, cx = -270 * s, cy = 290 * s;
    struct { int host; float dx, dy; ImU32 col; const char *l; } face[] = {
        {SDL_GAMEPAD_BUTTON_SOUTH, 0, -sp, XBOX_GREEN, "A"}, {SDL_GAMEPAD_BUTTON_EAST, sp, 0, XBOX_RED, "B"},
        {SDL_GAMEPAD_BUTTON_WEST, -sp, 0, XBOX_BLUE, "X"}, {SDL_GAMEPAD_BUTTON_NORTH, 0, sp, XBOX_YELLOW, "Y"}};
    for (auto &f : face) {
        Control &c = add(BUTTON, f.host, BR, cx + f.dx, cy + f.dy, fb, fb, f.l);
        c.accent = f.col, c.colored = true;
    }
    add(SHOULDER, SDL_GAMEPAD_BUTTON_LEFT_SHOULDER, TL, 165 * s, -95 * s, 210 * s, 84 * s, "LB").hit = 1.15f;
    add(TRIGGER, PADB_LTRIGGER, TL, 395 * s, -100 * s, 150 * s, 112 * s, "LT").hit = 1.15f;
    add(SHOULDER, SDL_GAMEPAD_BUTTON_RIGHT_SHOULDER, TR, -165 * s, -95 * s, 210 * s, 84 * s, "RB").hit = 1.15f;
    add(TRIGGER, PADB_RTRIGGER, TR, -395 * s, -100 * s, 150 * s, 112 * s, "RT").hit = 1.15f;
    add(BUTTON, SDL_GAMEPAD_BUTTON_BACK, TC, -85 * s, -72 * s, 80 * s, 80 * s).icon = ICON_VIEW;
    add(BUTTON, SDL_GAMEPAD_BUTTON_START, TC, 85 * s, -72 * s, 80 * s, 80 * s).icon = ICON_MENU;
    add(BUTTON, SDL_GAMEPAD_BUTTON_LEFT_STICK, BL, 510 * s, 120 * s, 76 * s, 76 * s, "L3");
    add(BUTTON, SDL_GAMEPAD_BUTTON_RIGHT_STICK, BR, -575 * s, 355 * s, 76 * s, 76 * s, "R3");
    add(BUTTON, -1, TC, 255 * s, -72 * s, 68 * s, 68 * s).icon = ICON_GEAR;
}

// ------------------------------------------------------------------ fingers -> state (main thread)
static bool hits(const Control &c, float x, float y) {
    if (c.kind == STICK && c.left && g_settings.touch_floating) return x < g_zone_x1 && y > g_zone_y0;
    if (c.kind == SHOULDER || c.kind == TRIGGER)
        return fabsf(x - c.x) <= c.w * 0.5f * c.hit && fabsf(y - c.y) <= c.h * 0.5f * c.hit;
    float r = c.w * 0.5f * c.hit, dx = x - c.x, dy = y - c.y;
    return dx * dx + dy * dy <= r * r;
}

static void publish(void) {
    uint32_t host = 0;
    int32_t ax[4] = {0, 0, 0, 0};  // lx, ly, rx, ry
    for (const Control &c : g_ctl) {
        switch (c.kind) {
        case BUTTON: case SHOULDER: case TRIGGER:
            if (c.pressed && c.host >= 0) host |= 1u << c.host;
            break;
        case DPAD:
            for (int i = 0; i < 4; i++)  // (taps are one-frame presses; with "D-pad moves Link" a held direction)
                if (g_settings.dpad_move ? c.dir[i] : c.pulse[i]) host |= 1u << DPAD_HOST[i];
            break;
        case STICK: {
            float r = c.w * 0.5f;
            int32_t vx = (int32_t)lroundf(c.kx / r * 32767), vy = (int32_t)lroundf(-c.ky / r * 32767);
            ax[c.left ? 0 : 2] = vx, ax[c.left ? 1 : 3] = vy;
            break;
        }
        }
    }
    input_touch_set(g_shown, host, ax[0], ax[1], ax[2], ax[3]);
    pthread_mutex_lock(&g_lock);
    g_snap = g_ctl;
    pthread_mutex_unlock(&g_lock);
}

static void release_all(void) {
    for (auto &f : g_owner) g_ignore.insert(f.first);
    g_owner.clear();
    for (Control &c : g_ctl) {
        c.owned = c.pressed = false;
        memset(c.dir, 0, sizeof c.dir), memset(c.pulse, 0, sizeof c.pulse);
        c.kx = c.ky = 0, c.x = c.hx, c.y = c.hy;
    }
}

static void stick_drag(Control &c, float x, float y) {
    float dx = x - c.x, dy = y - c.y, r = c.w * 0.5f, m = sqrtf(dx * dx + dy * dy);
    if (m > r) dx *= r / m, dy *= r / m;
    c.kx = dx, c.ky = dy;
}

// A finger on the d-pad: the direction(s) under it (8 ways: diagonals only within 12 degrees of 45 / 135 / ...)
static void dpad_drag(Control &c, float x, float y) {
    float vx = x - c.x, vy = c.y - y, r = c.w * 0.5f;
    bool next[4] = {};
    if (sqrtf(vx * vx + vy * vy) > r * 0.18f) {
        float ang = atan2f(vy, vx) * 57.2957795f;
        if (ang < 0) ang += 360;
        int k = (int)lroundf(ang / 90) % 4;
        float off = ang - k * 90;
        if (off > 180) off -= 360;
        next[k] = true;
        if (fabsf(off) > 33) next[(k + (off > 0 ? 1 : 3)) % 4] = true;
    }
    uint64_t now = SDL_GetTicks();
    for (int i = 0; i < 4; i++) {
        if (next[i] && !c.dir[i]) {
            c.dir[i] = true, c.since[i] = now, c.next_pulse[i] = now + 400, c.pulse[i] = true;
            haptic_tap();
        } else if (!next[i]) c.dir[i] = false;
    }
}

static void down(int i, SDL_FingerID f, float x, float y) {
    Control &c = g_ctl[(size_t)i];
    c.finger = f, c.owned = true, c.pressed = true;
    g_owner[f] = i;
    switch (c.kind) {
    case STICK:
        if (c.left && g_settings.touch_floating) c.x = x, c.y = y;
        stick_drag(c, x, y);
        break;
    case DPAD: dpad_drag(c, x, y); break;
    default: haptic_tap(); break;
    }
}

static void up(int i) {
    Control &c = g_ctl[(size_t)i];
    bool gear = c.kind == BUTTON && c.icon == ICON_GEAR && c.pressed;
    c.owned = c.pressed = false;
    memset(c.dir, 0, sizeof c.dir);  // (a pulse already sent still reaches the game: input.c note_press)
    c.kx = c.ky = 0, c.x = c.hx, c.y = c.hy;
    if (gear) menu_open_tab(MENU_TAB_PHONE);
}

static bool begin(SDL_FingerID f, float x, float y) {
    g_ignore.erase(f);
    auto o = g_owner.find(f);
    if (o != g_owner.end()) { up(o->second); g_owner.erase(o); }
    int hit = -1;  // (buttons before sticks: the sticks and the floating zone are the largest targets)
    for (size_t i = 0; i < g_ctl.size() && hit < 0; i++)
        if (g_ctl[i].kind != STICK && !g_ctl[i].owned && hits(g_ctl[i], x, y)) hit = (int)i;
    for (size_t i = 0; i < g_ctl.size() && hit < 0; i++)
        if (g_ctl[i].kind == STICK && !g_ctl[i].owned && hits(g_ctl[i], x, y)) hit = (int)i;
    if (hit < 0) return false;
    down(hit, f, x, y);
    return true;
}

static bool move(SDL_FingerID f, float x, float y) {
    if (g_ignore.count(f)) return true;
    auto o = g_owner.find(f);
    if (o == g_owner.end()) return false;
    Control &c = g_ctl[(size_t)o->second];
    switch (c.kind) {
    case STICK: stick_drag(c, x, y); break;
    case DPAD: dpad_drag(c, x, y); break;
    case BUTTON:
        if (c.colored && !hits(c, x, y))  // sliding onto a neighbouring face button moves the press there
            for (size_t i = 0; i < g_ctl.size(); i++)
                if (g_ctl[i].colored && !g_ctl[i].owned && hits(g_ctl[i], x, y)) {
                    up(o->second);
                    g_owner.erase(f);
                    down((int)i, f, x, y);
                    break;
                }
        break;
    default: break;
    }
    return true;
}

static bool end(SDL_FingerID f) {
    bool ignored = g_ignore.erase(f) > 0;
    auto o = g_owner.find(f);
    if (o == g_owner.end()) return ignored;
    up(o->second);
    g_owner.erase(o);
    return true;
}

// ------------------------------------------------------------------ main thread entry points
static int g_W, g_H, g_size_built, g_floating_built = -1;
static SDL_Rect g_safe;

void touch_init(void) {
    if (!enabled()) return;
    SDL_Log("[touch] on-screen controller %s", TOUCH_PHONE ? "(phone)" : "(LARECOMP_TOUCH test: the mouse is the finger)");
}

bool touch_handle_event(const SDL_Event *e) {
    if (!enabled() || !g_shown) return false;
    SDL_Window *win = ui_window();
    switch (e->type) {
    case SDL_EVENT_FINGER_DOWN: case SDL_EVENT_FINGER_MOTION: case SDL_EVENT_FINGER_UP: case SDL_EVENT_FINGER_CANCELED: {
        int w = 0, h = 0;
        SDL_GetWindowSizeInPixels(win, &w, &h);
        float x = e->tfinger.x * w, y = e->tfinger.y * h;
        bool used = e->type == SDL_EVENT_FINGER_DOWN ? begin(e->tfinger.fingerID, x, y)
                  : e->type == SDL_EVENT_FINGER_MOTION ? move(e->tfinger.fingerID, x, y)
                                                       : end(e->tfinger.fingerID);
        if (used) publish();
        return used;
    }
    case SDL_EVENT_MOUSE_BUTTON_DOWN: case SDL_EVENT_MOUSE_BUTTON_UP: case SDL_EVENT_MOUSE_MOTION: {
        if (e->type == SDL_EVENT_MOUSE_MOTION ? e->motion.which == SDL_TOUCH_MOUSEID : e->button.which == SDL_TOUCH_MOUSEID)
            return !g_owner.empty() || !g_ignore.empty();  // (SDL's copy of a finger: the finger itself counted above)
        if (TOUCH_PHONE) return false;
        float d = SDL_GetWindowPixelDensity(win);  // (LARECOMP_TOUCH test: the left button is finger 1)
        bool used;
        if (e->type == SDL_EVENT_MOUSE_MOTION) used = (e->motion.state & SDL_BUTTON_LMASK) && move(1, e->motion.x * d, e->motion.y * d);
        else if (e->button.button != SDL_BUTTON_LEFT) return false;
        else used = e->type == SDL_EVENT_MOUSE_BUTTON_DOWN ? begin(1, e->button.x * d, e->button.y * d) : end(1);
        if (used) publish();
        return used;
    }
    default:
        return false;
    }
}

void touch_frame(void) {
    if (!enabled()) return;
    SDL_Window *win = ui_window();
    if (!win) return;
    if (g_share_req.exchange(false)) share_logs();
    int w = 0, h = 0;
    SDL_GetWindowSizeInPixels(win, &w, &h);
    g_panel_w = w > h ? w : h, g_panel_h = w > h ? h : w;
    SDL_Rect safe = {0, 0, 0, 0};
    SDL_GetWindowSafeArea(win, &safe);
    bool show = g_settings.touch_controls && !SDL_HasGamepad() && !menu_input_captured() && w > 0 && h > 0;
    bool changed = false;
    // a new screen size / safe area / Touch Size / Left Stick: laid out again - what is held is released, and its
    // fingers are ignored until they lift (a control moving under a finger would read another direction)
    if (w != g_W || h != g_H || memcmp(&safe, &g_safe, sizeof safe) || g_settings.touch_size != g_size_built ||
        (int)g_settings.touch_floating != g_floating_built) {
        if (!g_ctl.empty()) release_all();
        g_W = w, g_H = h, g_safe = safe, g_size_built = g_settings.touch_size, g_floating_built = g_settings.touch_floating;
        layout(w, h, safe, SDL_GetWindowPixelDensity(win));
        changed = true;
    }
    if (show != g_shown) {
        g_shown = show;
        if (!show) release_all();
        SDL_Log("[touch] on-screen controller %s", show ? "shown" : SDL_HasGamepad() ? "hidden (controller connected)" : "hidden");
        changed = true;
    }
    // the d-pad's taps: a press lasts one pass (the game still sees it: input.c note_press); held, steady repeats
    // after 0.4 s every 0.15 s - the game's own repeat after a quick release turned taps into double steps
    uint64_t now = SDL_GetTicks();
    for (Control &c : g_ctl) {
        if (c.kind != DPAD) continue;
        for (int i = 0; i < 4; i++) {
            bool p = c.dir[i] && now >= c.next_pulse[i];
            if (p) c.next_pulse[i] = now + 150;
            if (c.pulse[i] != p) c.pulse[i] = p, changed = true;
        }
    }
    if (changed) publish();
    g_draw = show;
}

bool touch_overlay_wanted(void) { return g_draw.load(); }

// ------------------------------------------------------------------ drawing (render thread)
static ImU32 rgba(ImU32 c, float a) {
    int al = (int)lroundf(((c >> IM_COL32_A_SHIFT) & 0xFF) * (a < 0 ? 0 : a > 1 ? 1 : a));
    return (c & ~IM_COL32_A_MASK) | ((ImU32)al << IM_COL32_A_SHIFT);
}
static const ImU32 BODY = IM_COL32(19, 20, 26, 255), WHITE = IM_COL32(255, 255, 255, 255),
                   NEUTRAL = IM_COL32(235, 240, 255, 255), SHADOW = IM_COL32(0, 0, 0, 255);

static void text_centered(ImDrawList *dl, ImVec2 c, float size, ImU32 col, const char *t) {
    ImFont *f = ImGui::GetFont();
    ImVec2 ts = f->CalcTextSizeA(size, FLT_MAX, 0, t);
    dl->AddText(f, size, ImVec2(c.x - ts.x * 0.5f + size * 0.02f, c.y - ts.y * 0.5f + size * 0.04f), rgba(SHADOW, 0.6f), t);
    dl->AddText(f, size, ImVec2(c.x - ts.x * 0.5f, c.y - ts.y * 0.5f), col, t);
}

static void draw_icon(ImDrawList *dl, ImVec2 c, float s, Icon icon, ImU32 col) {
    float t = s * 0.07f;
    switch (icon) {
    case ICON_VIEW:  // two overlapping windows
        dl->AddRect(ImVec2(c.x - s * 0.10f, c.y - s * 0.20f), ImVec2(c.x + s * 0.24f, c.y + s * 0.06f), col, s * 0.04f, 0, t);
        dl->AddRectFilled(ImVec2(c.x - s * 0.24f, c.y - s * 0.06f), ImVec2(c.x + s * 0.10f, c.y + s * 0.20f), col, s * 0.04f);
        break;
    case ICON_MENU:  // three lines
        for (int i = -1; i <= 1; i++)
            dl->AddLine(ImVec2(c.x - s * 0.22f, c.y + i * s * 0.13f), ImVec2(c.x + s * 0.22f, c.y + i * s * 0.13f), col, t);
        break;
    case ICON_GEAR: {
        float ro = s * 0.27f, ri = s * 0.19f;
        for (int i = 0; i < 8; i++) {
            float a = i * 0.785398f;
            ImVec2 d(cosf(a), sinf(a));
            dl->AddLine(ImVec2(c.x + d.x * ri, c.y + d.y * ri), ImVec2(c.x + d.x * ro, c.y + d.y * ro), col, s * 0.11f);
        }
        dl->AddCircle(c, ri, col, 24, s * 0.08f);
        dl->AddCircleFilled(c, s * 0.07f, col, 12);
        break;
    }
    case ICON_NONE: break;
    }
}

static void draw_disc(ImDrawList *dl, ImVec2 c, float r, float a, float press, ImU32 accent, bool colored) {
    dl->AddCircleFilled(ImVec2(c.x, c.y + r * 0.10f), r * 1.12f, rgba(SHADOW, 0.35f * a), 40);
    if (press > 0) dl->AddCircleFilled(c, r * 1.30f, rgba(accent, 0.45f * press), 40);
    dl->AddCircleFilled(c, r, rgba(BODY, (0.80f + 0.12f * press) * a + 0.05f), 40);
    if (press > 0) dl->AddCircleFilled(c, r, rgba(accent, 0.35f * press), 40);
    dl->AddCircleFilled(ImVec2(c.x, c.y - r * 0.35f), r * 0.55f, rgba(WHITE, 0.06f * a), 32);  // (the glass's shine)
    ImU32 rim = colored ? accent : WHITE;
    dl->AddCircle(c, r, rgba(rim, (0.55f + 0.45f * press) * a + 0.12f), 40, r * 0.06f);
}

void touch_overlay_draw(const ImVec2 &display) {
    (void)display;
    std::vector<Control> ctl;
    pthread_mutex_lock(&g_lock);
    ctl = g_snap;
    pthread_mutex_unlock(&g_lock);
    ImDrawList *dl = ImGui::GetForegroundDrawList();
    float a = g_settings.touch_opacity / 100.0f;
    for (const Control &c : ctl) {
        float p = c.pressed ? 1.0f : 0.0f;
        ImVec2 o(c.x, c.y);
        switch (c.kind) {
        case BUTTON: {
            float r = c.w * 0.5f * (1 - 0.06f * p);
            draw_disc(dl, o, r, a, p, c.accent, c.colored);
            ImU32 lc = rgba(c.colored ? c.accent : NEUTRAL, a * 1.25f + 0.2f);
            if (c.icon) draw_icon(dl, o, c.w, c.icon, lc);
            else text_centered(dl, o, c.w * (c.colored ? 0.5f : 0.38f), lc, c.label);
            break;
        }
        case SHOULDER: case TRIGGER: {
            float k = 1 - 0.05f * p, hw = c.w * 0.5f * k, hh = c.h * 0.5f * k;
            float round = c.kind == TRIGGER ? hh * 0.55f : hh * 0.9f;
            ImVec2 a0(o.x - hw, o.y - hh), a1(o.x + hw, o.y + hh);
            dl->AddRectFilled(ImVec2(a0.x, a0.y + hh * 0.15f), ImVec2(a1.x, a1.y + hh * 0.15f), rgba(SHADOW, 0.35f * a), round);
            dl->AddRectFilled(a0, a1, rgba(BODY, (0.80f + 0.12f * p) * a + 0.05f), round);
            if (p > 0) dl->AddRectFilled(a0, a1, rgba(WHITE, 0.22f * p), round);
            dl->AddRect(a0, a1, rgba(WHITE, (0.55f + 0.45f * p) * a + 0.12f), round, 0, c.h * 0.05f);
            text_centered(dl, o, c.h * 0.46f, rgba(NEUTRAL, a * 1.25f + 0.2f), c.label);
            break;
        }
        case DPAD: {
            float s = c.w, arm = s * 0.34f, half = s * 0.47f;
            dl->AddCircleFilled(o, s * 0.55f, rgba(BODY, 0.42f * a + 0.03f), 48);
            dl->AddCircle(o, s * 0.55f, rgba(WHITE, 0.30f * a + 0.05f), 48, s * 0.012f);
            ImU32 body = rgba(BODY, 0.85f * a + 0.06f), rim = rgba(WHITE, 0.55f * a + 0.12f);
            ImVec2 h0(o.x - half, o.y - arm / 2), h1(o.x + half, o.y + arm / 2);
            ImVec2 v0(o.x - arm / 2, o.y - half), v1(o.x + arm / 2, o.y + half);
            dl->AddRectFilled(h0, h1, body, arm * 0.2f);
            dl->AddRectFilled(v0, v1, body, arm * 0.2f);
            // pressed arms light up; arrows on each (right, up, left, down)
            static const float dx[4] = {1, 0, -1, 0}, dy[4] = {0, -1, 0, 1};
            for (int i = 0; i < 4; i++) {
                ImVec2 ac(o.x + dx[i] * s * 0.315f, o.y + dy[i] * s * 0.315f);
                if (c.dir[i])
                    dl->AddRectFilled(ImVec2(ac.x - arm / 2, ac.y - arm / 2), ImVec2(ac.x + arm / 2, ac.y + arm / 2),
                                      rgba(WHITE, 0.30f), arm * 0.2f);
                float t = s * 0.07f;
                ImVec2 tip(ac.x + dx[i] * t, ac.y + dy[i] * t), b(ac.x - dx[i] * t * 0.6f, ac.y - dy[i] * t * 0.6f);
                ImVec2 n(-dy[i] * t, dx[i] * t);
                dl->AddTriangleFilled(tip, ImVec2(b.x + n.x, b.y + n.y), ImVec2(b.x - n.x, b.y - n.y),
                                      rgba(WHITE, (0.75f + 0.25f * c.dir[i]) * a * 1.2f + 0.1f));
            }
            dl->AddRect(h0, h1, rim, arm * 0.2f, 0, s * 0.012f);
            dl->AddRect(v0, v1, rim, arm * 0.2f, 0, s * 0.012f);
            dl->AddCircleFilled(o, s * 0.08f, rgba(IM_COL32(64, 66, 77, 255), 0.8f * a), 16);
            break;
        }
        case STICK: {
            float r = c.w * 0.5f, ba = c.left && g_settings.touch_floating && !c.pressed ? a * 0.7f : a;
            dl->AddCircleFilled(ImVec2(o.x, o.y + r * 0.06f), r * 1.1f, rgba(SHADOW, 0.30f * ba), 48);
            dl->AddCircleFilled(o, r, rgba(BODY, 0.55f * ba + 0.06f), 48);
            dl->AddCircle(o, r, rgba(WHITE, 0.40f * ba + 0.06f), 48, r * 0.03f);
            ImVec2 k(o.x + c.kx, o.y + c.ky);
            float kr = r * 0.525f * (1 + 0.06f * p);
            dl->AddCircleFilled(ImVec2(k.x, k.y + kr * 0.12f), kr * 1.1f, rgba(SHADOW, 0.5f * a), 40);
            if (p > 0) dl->AddCircleFilled(k, kr * 1.3f, rgba(WHITE, 0.25f * p), 40);
            dl->AddCircleFilled(k, kr, rgba(IM_COL32(48, 51, 61, 255), 0.85f * a + 0.1f), 40);
            dl->AddCircle(k, kr * 0.65f, rgba(WHITE, 0.25f * a), 32, kr * 0.03f);
            dl->AddCircle(k, kr, rgba(WHITE, (0.45f + 0.4f * p) * a + 0.08f), 40, kr * 0.06f);
            break;
        }
        }
    }
}

// ------------------------------------------------------------------ Phone tab (render thread, the menu)
float phone_ui_scale(void) {
#if TOUCH_PHONE
    static const float k[3] = {0.85f, 1.0f, 1.2f};  // Small / Default / Large on the phone's baseline
    int i = g_settings.phone_ui_size;
    return 1.3f * k[i >= 0 && i <= 2 ? i : 1];
#else
    return 1.0f;
#endif
}

// (the log) every change of a Phone row, from what the rows held before this frame's drawing
static void log_phone_changes(const Settings &was) {
    const Settings &s = g_settings;
    struct { const char *name; int before, now; } rows[] = {
        {"resolution", was.phone_resolution, s.phone_resolution}, {"dynamic", was.phone_dynamic, s.phone_dynamic},
        {"aspect", was.phone_aspect, s.phone_aspect}, {"scaling", was.phone_scaling, s.phone_scaling},
        {"frame_rate", was.phone_frame_rate, s.phone_frame_rate}, {"auto30", was.phone_auto30, s.phone_auto30},
        {"show_fps", was.show_fps, s.show_fps},
        {"ui_size", was.phone_ui_size, s.phone_ui_size}, {"touch", was.touch_controls, s.touch_controls},
        {"touch_opacity", was.touch_opacity, s.touch_opacity}, {"touch_size", was.touch_size, s.touch_size},
        {"floating_stick", was.touch_floating, s.touch_floating}, {"vibration", was.phone_vibration, s.phone_vibration},
        {"upscaler", was.upscaler, s.upscaler}, {"antialias", was.antialias, s.antialias}};
    for (auto &r : rows)
        if (r.before != r.now) fprintf(stderr, "[phone] setting %s: %d -> %d\n", r.name, r.before, r.now);
}

void phone_rows_draw(void) {
    static Settings was;  // (the rows' values before this frame: what changed goes to the log)
    static bool have;
    if (have) log_phone_changes(was);
    was = g_settings, have = true;
    opt_section("Display");
    char native[48];
    snprintf(native, sizeof native, "Native (%dx%d)", g_panel_w.load(), g_panel_h.load());
    const char *res[N_PHONE_RES] = {native, "2106x1084", "1920x1080", "1600x900", "1280x720"};
    opt_choice("Resolution", &g_settings.phone_resolution, res, N_PHONE_RES, PHONE_RES_NATIVE,
               "How many lines the game renders, scaled to the screen. Native: the screen's own. Lower is easier on "
               "the battery and keeps the iPhone cooler; the image is scaled up with the Upscaler below.");
    opt_toggle("Dynamic Resolution", &g_settings.phone_dynamic, false,
               "On: keeps 60 fps - when the iPhone can't keep up (a busy scene, or the phone warming up after a while) "
               "the game is drawn a little lower than the Resolution above, and goes back up when it can. Off: always "
               "the Resolution above.");
    static const char *aspects[N_PHONE_ASPECTS] = {"iPhone Default", "1.943:1", "16:9", "4:3"};
    opt_choice("Aspect Ratio", &g_settings.phone_aspect, aspects, N_PHONE_ASPECTS, PHONE_ASPECT_DEVICE,
               "The shape of the game image. iPhone Default fills the screen and shows more of the island at the "
               "sides; 16:9 is the game's own framing. Houses and dungeons keep their 16:9 framing either way.");
    static const char *scaling[] = {"Fit", "Stretch"};
    opt_choice("Screen Scaling", &g_settings.phone_scaling, scaling, 2, PHONE_SCALE_FIT,
               "Fit: the image keeps its shape, with black bars around it. Stretch: it is stretched over the whole "
               "screen.");
    static const char *fps[] = {"30 FPS", "60 FPS", "60 FPS, 120 Hz"};
    opt_choice("Frame Rate", &g_settings.phone_frame_rate, fps, 3, PHONE_FPS_60,
               "30: the game's own 30 fps mode all the time - cooler, longer battery. 60: as on the Switch, the most "
               "the game itself runs at (its timing is built on 60 frames a second). 60 FPS, 120 Hz: on a ProMotion "
               "screen each frame is shown at the next 120 Hz refresh, a little sooner after your input - still 60 "
               "frames. (Inside LiveContainer the screen may stay at 60 Hz: it uses LiveContainer's settings.)");
    if (g_settings.phone_frame_rate == PHONE_FPS_30) opt_disable_next();  // (30 already)
    opt_toggle("Drop to 30 FPS When Slow", &g_settings.phone_auto30, false,
               "Off: the frame rate is never capped to 30 by itself - when the iPhone can't keep up (a busy scene, the "
               "phone warm) you see the frame rate it manages, like 45 or 50. On: the game switches to its own steady "
               "30 fps mode then, as on the Switch.");
    opt_toggle("Show FPS", &g_settings.show_fps, false, "Shows the frame rate in the top right corner.");
    static const char *ui[] = {"Small", "Default", "Large"};
    opt_choice("UI Size", &g_settings.phone_ui_size, ui, 3, 1, "The size of these menus and the overlays.");

    opt_section("Touch controls");
    opt_toggle("Touch Controls", &g_settings.touch_controls, true,
               "The on-screen controller. It hides by itself while a controller is connected.");
    opt_int("Touch Opacity", &g_settings.touch_opacity, 20, 100, 5, 65, "%d%%", "How solid the on-screen controls look.");
    opt_int("Touch Size", &g_settings.touch_size, 70, 150, 10, 100, "%d%%", "The size of the on-screen controls.");
    int floating = g_settings.touch_floating;
    static const char *stick[] = {"Fixed", "Floating"};
    if (opt_choice("Left Stick", &floating, stick, 2, 0,
                   "Fixed: the stick stays in the corner. Floating: it appears where your thumb lands in the left part "
                   "of the screen."))
        g_settings.touch_floating = floating != 0;
    opt_toggle("Vibration", &g_settings.phone_vibration, true,
               "A light tap when you press an on-screen control, and the game's rumble on the iPhone itself when no "
               "controller is connected.");

    opt_section("Logs");
    if (opt_button("Share Log", "Sends this session's log (lasrecomp.log: frame rate, resolution, heat, memory, "
                                "settings, errors) with AirDrop, Messages, Files... - for bug reports."))
        g_share_req = true;
}

// ------------------------------------------------------------------ Share Log (main thread: UIKit)
#if TOUCH_PHONE && defined(__OBJC__)
static void share_logs(void) {
    fflush(stderr);
    NSMutableArray *items = [NSMutableArray array];
    for (const char *name : {"lasrecomp.log", "last_error.txt"}) {
        char p[1200];
        snprintf(p, sizeof p, "%s/%s", rt_data_root(), name);
        if (access(p, R_OK) == 0) [items addObject:[NSURL fileURLWithPath:@(p)]];
    }
    SDL_Window *win = ui_window();
    UIWindow *w = win ? (__bridge UIWindow *)SDL_GetPointerProperty(SDL_GetWindowProperties(win),
                                                                    SDL_PROP_WINDOW_UIKIT_WINDOW_POINTER, NULL) : nil;
    UIViewController *vc = w.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    if (!vc || items.count == 0) { fprintf(stderr, "[phone] Share Log: nothing to share / no window\n"); return; }
    UIActivityViewController *a = [[UIActivityViewController alloc] initWithActivityItems:items applicationActivities:nil];
    a.popoverPresentationController.sourceView = vc.view;  // (iPad: a popover from the middle of the screen)
    a.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(vc.view.bounds), CGRectGetMidY(vc.view.bounds), 1, 1);
    [vc presentViewController:a animated:YES completion:nil];
    fprintf(stderr, "[phone] Share Log: %lu file(s)\n", (unsigned long)items.count);
}
#else
static void share_logs(void) {}
#endif
