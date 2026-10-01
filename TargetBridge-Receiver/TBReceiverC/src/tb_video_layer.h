#ifndef TB_VIDEO_LAYER_H
#define TB_VIDEO_LAYER_H

#include <stddef.h>
#include <stdint.h>

/* Video output through AVSampleBufferDisplayLayer.
 * Compressed samples go straight to the system decoder and decoded IOSurfaces
 * are composited as-is, avoiding the GPU→CPU→GPU copy and synchronous decode
 * on the main loop. */

struct tb_video_layer;

struct tb_video_layer_stats {
    uint64_t enqueued;
    uint64_t dropped_not_ready;
    uint64_t dropped_wait_key;
    uint64_t flushes;
};

/* nswindow: NSWindow*, metal_layer: SDL's CAMetalLayer* (hidden while video shows). */
struct tb_video_layer *tb_vlayer_create(void *nswindow, void *metal_layer);
void tb_vlayer_destroy(struct tb_video_layer *v);

/* Returned when the stream is HEVC Main10 but this Mac cannot decode it in
 * hardware fast enough; the caller should renegotiate without Main10. */
#define TB_VLAYER_MAIN10_UNSUPPORTED (-2)
/* Main10 decoded but repeatedly fell behind (may be transient, e.g. occlusion). */
#define TB_VLAYER_MAIN10_TOO_SLOW (-3)

/* 0: applied, 1: unchanged, TB_VLAYER_MAIN10_UNSUPPORTED, <0: parse or format creation failed. */
int  tb_vlayer_set_param_sets(struct tb_video_layer *v, const uint8_t *payload, size_t len);

/* 1: enqueued, 0: dropped, TB_VLAYER_MAIN10_TOO_SLOW, <0: layer unrecoverable (switch to FFmpeg). */
int  tb_vlayer_enqueue(struct tb_video_layer *v, const uint8_t *avcc, size_t len);

void tb_vlayer_set_visible(struct tb_video_layer *v, int visible);
/* argb: premultiplied ARGB8888, dim x dim, hotspot at (hotspot, hotspot). */
void tb_vlayer_set_cursor_image(struct tb_video_layer *v, const uint8_t *argb, int dim, int hotspot);
void tb_vlayer_set_cursor(struct tb_video_layer *v, double x_norm, double y_norm, int visible,
                          int source_w, int large);
/* Native cursor bitmap; geometry in source (capture) pixels. Returns 0 on success. */
int  tb_vlayer_set_cursor_png(struct tb_video_layer *v, const uint8_t *png, size_t len,
                              int hotspot_x, int hotspot_y, int width, int height);
/* Built-in arrow used when no cursor sprite or bitmap can be produced. */
void tb_vlayer_use_fallback_cursor(struct tb_video_layer *v, int size);
/* Re-place the cursor after the view size changes. */
void tb_vlayer_refresh_cursor(struct tb_video_layer *v);
int  tb_vlayer_has_format(struct tb_video_layer *v);
/* Current stream is HEVC Main10 (only the video layer can display it). */
int  tb_vlayer_is_main10(struct tb_video_layer *v);
/* Cached probe: hardware decoder available for HEVC Main10. */
int  tb_vlayer_supports_main10_hw(void);
void tb_vlayer_reset(struct tb_video_layer *v);
void tb_vlayer_get_size(struct tb_video_layer *v, int *w, int *h);
void tb_vlayer_take_stats(struct tb_video_layer *v, struct tb_video_layer_stats *out);

#endif
