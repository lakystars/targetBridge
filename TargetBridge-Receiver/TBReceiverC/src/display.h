/* display.h — SDL2 fullscreen window + NV12 GPU texture renderer. */

#ifndef TB_DISPLAY_H
#define TB_DISPLAY_H

#include <stdint.h>
#include <stddef.h>

#include "input_queue.h"

struct tb_display;

struct tb_display_info {
    uint32_t logical_w;
    uint32_t logical_h;
    uint32_t active_w;
    uint32_t active_h;
    uint32_t window_w;
    uint32_t window_h;
    uint32_t drawable_w;
    uint32_t drawable_h;
    char     name[128];
};

enum tb_display_action {
    TB_DISP_ACTION_NONE = 0,
    TB_DISP_ACTION_QUIT = 1 << 0,
    TB_DISP_ACTION_CYCLE_LANGUAGE = 1 << 1,
    TB_DISP_ACTION_TOGGLE_VIDEO_LAYER = 1 << 2,
    TB_DISP_ACTION_TOGGLE_MAIN10 = 1 << 3
};

struct tb_display *tb_disp_create(int fullscreen, int prefer_metal);
void               tb_disp_destroy(struct tb_display *d);
void               tb_disp_set_connection_state(struct tb_display *d, int connected);
void               tb_disp_set_input_capture_active(struct tb_display *d, int active);
void               tb_disp_set_input_intercept_active(struct tb_display *d, int active);

/* Whether the receiver display window is on the active macOS Space. Used to
 * gate receiverMaster global-tap forwarding so input on other receiver Spaces
 * does not leak to the sender. */
int                tb_disp_window_on_active_space(struct tb_display *d);

/* Resize/recreate texture when frame dimensions change. */
int  tb_disp_ensure_texture(struct tb_display *d, int w, int h);

/* External video layer integration (tb_video_layer). */
/* Recreates the SDL renderer (Metal-first or OpenGL-first); textures are rebuilt lazily. */
int   tb_disp_switch_renderer(struct tb_display *d, int prefer_metal);
/* Extra idle-screen lines (newline-separated): video output and 10-bit state. */
void  tb_disp_set_footer_note(struct tb_display *d, const char *note);
void *tb_disp_cocoa_window(struct tb_display *d);
void *tb_disp_metal_layer(struct tb_display *d);
void  tb_disp_set_external_video(struct tb_display *d, int active);
void  tb_disp_present_external_frame(struct tb_display *d);

struct tb_cursor_state {
    int    visible;
    double x_norm;
    double y_norm;
    int    type;
    int    size;
    int    large;
    int    source_w;
};
/* Returns 1 and fills out when the cursor changed in external video mode. */
int  tb_disp_take_cursor_update(struct tb_display *d, struct tb_cursor_state *out);
/* Renders a premultiplied ARGB cursor sprite; caller frees pixels. */
int  tb_disp_render_cursor_sprite(struct tb_display *d, int type, int size,
                                  uint8_t **pixels, int *dim, int *hotspot);

/* Upload NV12 planes + render. Called once per decoded frame. */
void tb_disp_render_nv12(struct tb_display *d,
                         const uint8_t *y, int y_stride,
                         const uint8_t *uv, int uv_stride,
                         int w, int h);

/* Update low-latency local cursor overlay in source-frame coordinates. */
void tb_disp_set_cursor(struct tb_display *d,
                        int x, int y,
                        int source_w, int source_h,
                        int visible,
                        int type,
                        int large);

void tb_disp_set_brightness(struct tb_display *d, double level);

/* Poll input actions while idle/connected. */
unsigned int tb_disp_poll_actions(struct tb_display *d);
int          tb_disp_pop_input_event(struct tb_display *d, struct tb_input_event *out);

/* Query active display/window/drawable information for UI/debug metadata. */
int  tb_disp_get_info(struct tb_display *d, struct tb_display_info *info);

/* Render a simple launcher/status UI before the video stream starts. */
void tb_disp_render_status(struct tb_display *d,
                           const char *ip,
                           const char *status,
                           const char *sender,
                           const char *panel,
                           const char *mode,
                           const char *language,
                           const char *permissions);
void tb_disp_render_connecting(struct tb_display *d);

#endif
