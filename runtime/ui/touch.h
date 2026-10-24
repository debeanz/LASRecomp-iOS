// On-screen controller and phone settings (runtime/ui/touch.mm): an Xbox-style touch controller over the game on
// iPhone (the same layout and Phone settings rows in every port of this kind), feeding the game through the controller
// bindings like a connected pad (runtime/hle/input.c input_touch_set). Hidden while a controller is connected, while
// the menu or a name entry is up (fingers then go to the menu as mouse clicks), and when switched off in the Phone tab.
// Elsewhere it is off, unless LARECOMP_TOUCH=1 (test: the mouse is the finger).
#pragma once
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef union SDL_Event SDL_Event;

void touch_init(void);                        // main thread, once the window exists
bool touch_handle_event(const SDL_Event *e);  // main thread: true = a finger on the controls (the event is consumed)
void touch_frame(void);                       // main thread, once per event loop pass (repeats, showing / hiding)
bool touch_overlay_wanted(void);              // render thread: the overlay is to be drawn this frame
bool touch_rumble_wanted(void);               // UI thread: the game's rumble goes to the phone (no controller)
void touch_rumble(uint16_t lo, uint16_t hi);  // UI thread: the game's rumble now (SDL units), as haptic taps

// runtime/hle/input.c: the on-screen controller's state (host: SDL gamepad buttons by position + PADB_*TRIGGER bits;
// sticks in SDL units, y up)
void input_touch_set(bool on, uint32_t host, int32_t lx, int32_t ly, int32_t rx, int32_t ry);

#ifdef __cplusplus
}
struct ImVec2;
// Render thread, inside menu_render's ImGui frame: the overlay (display: the target's size in pixels)
void touch_overlay_draw(const ImVec2 &display);
// The phone settings rows (Display, Touch controls sections), at the top of the menu's Phone tab - the Video tab on
// iPhone (runtime/ui/menu.mm tab_display), inside its opt_begin / opt_end
void phone_rows_draw(void);
// The menus' size on the phone: the Phone tab's UI Size on top of the phone's baseline (1 elsewhere)
float phone_ui_scale(void);
#endif
