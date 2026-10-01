#import <AppKit/AppKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <QuartzCore/QuartzCore.h>
#import <VideoToolbox/VideoToolbox.h>
#import <ImageIO/ImageIO.h>

#include "tb_video_layer.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Targets macOS 13, so use the layer's own enqueue API. */
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

/* Consecutive decode failures tolerated before falling back to FFmpeg. */
#define TB_VLAYER_MAX_FAILURES 3
/* Enqueued frames without a failure before the failure count resets. */
#define TB_VLAYER_HEALTHY_FRAMES 300

/* Video host view that lets clicks through to the SDL view. */
@interface TBVideoHostView : NSView
@end

@implementation TBVideoHostView
- (NSView *)hitTest:(NSPoint)point {
    (void)point;
    return nil;
}
@end

struct tb_video_layer {
    NSView *view;
    CALayer *root;
    AVSampleBufferDisplayLayer *layer;
    CALayer *cursor;
    NSView *overlay;
    double cursor_x;
    double cursor_y;
    int cursor_visible;
    CGSize cursor_bounds;
    int cursor_source_w;
    int cursor_large;
    /* Native cursor bitmap mode: geometry in source pixels, applied per scale. */
    int cursor_image_mode;
    CGSize cursor_image_size;
    double cursor_image_scale;
    int cursor_dim;
    int cursor_hotspot;
    CMVideoFormatDescriptionRef fmt;
    int codec;
    int profile_idc;
    int width;
    int height;
    int need_keyframe;
    int failures;
    int frames_since_failure;
    uint8_t *last_ps;
    size_t last_ps_len;
    struct tb_video_layer_stats stats;
};

static uint32_t tb_vlayer_be32(const uint8_t *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | (uint32_t)p[3];
}

static int tb_vlayer_is_keyframe(int codec, const uint8_t *avcc, size_t len) {
    size_t off = 0;
    while (off + 5 <= len) {
        uint32_t nal_len = tb_vlayer_be32(avcc + off);
        off += 4;
        if (nal_len == 0 || nal_len > len - off) return 0;
        uint8_t header = avcc[off];
        if (codec == 2) {
            /* HEVC IRAP: BLA/IDR/CRA (16..21) */
            int type = (header >> 1) & 0x3f;
            if (type >= 16 && type <= 21) return 1;
        } else {
            if ((header & 0x1f) == 5) return 1;
        }
        off += nal_len;
    }
    return 0;
}

struct tb_video_layer *tb_vlayer_create(void *nswindow, void *metal_layer) {
    if (!nswindow || !metal_layer) return NULL;
    NSWindow *window = (__bridge NSWindow *)nswindow;
    NSView *content = window.contentView;
    if (!content) return NULL;
    /* AppKit owns `hidden` on backing layers, so hide SDL's Metal view instead. */
    id overlay = ((__bridge CAMetalLayer *)metal_layer).delegate;
    if (![overlay isKindOfClass:[NSView class]]) return NULL;

    struct tb_video_layer *v = calloc(1, sizeof(*v));
    if (!v) return NULL;

    /* Layer-hosting view: cursor layer above the video layer. */
    CALayer *root = [CALayer layer];
    root.backgroundColor = CGColorGetConstantColor(kCGColorBlack);

    AVSampleBufferDisplayLayer *layer = [AVSampleBufferDisplayLayer layer];
    layer.videoGravity = AVLayerVideoGravityResize;
    layer.backgroundColor = CGColorGetConstantColor(kCGColorBlack);
    layer.autoresizingMask = kCALayerWidthSizable | kCALayerHeightSizable;
    [root addSublayer:layer];

    CALayer *cursor = [CALayer layer];
    cursor.hidden = YES;
    cursor.actions = @{ @"position": [NSNull null], @"hidden": [NSNull null],
                        @"contents": [NSNull null], @"bounds": [NSNull null] };
    [root addSublayer:cursor];

    NSView *view = [[TBVideoHostView alloc] initWithFrame:content.bounds];
    view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    view.layer = root;
    view.wantsLayer = YES;
    view.hidden = YES;
    layer.frame = root.bounds;

    /* Sits below SDL's Metal view; the SDL overlay is hidden while video shows. */
    content.wantsLayer = YES;
    [content addSubview:view positioned:NSWindowBelow relativeTo:nil];

    v->view = view;
    v->root = root;
    v->layer = layer;
    v->cursor = cursor;
    v->overlay = (NSView *)overlay;
    v->need_keyframe = 1;
    fprintf(stderr, "[vlayer] AVSampleBufferDisplayLayer enabled\n");
    return v;
}

void tb_vlayer_destroy(struct tb_video_layer *v) {
    if (!v) return;
    [v->layer flushAndRemoveImage];
    [v->view removeFromSuperview];
    v->overlay.hidden = NO;
    v->view = nil;
    v->root = nil;
    v->layer = nil;
    v->cursor = nil;
    v->overlay = nil;
    if (v->fmt) CFRelease(v->fmt);
    free(v->last_ps);
    free(v);
}

static int tb_vlayer_apply_param_sets(struct tb_video_layer *v, const uint8_t *payload, size_t len);

int tb_vlayer_set_param_sets(struct tb_video_layer *v, const uint8_t *payload, size_t len) {
    int r = tb_vlayer_apply_param_sets(v, payload, len);
    /* Do not decode further frames against a stale format. */
    if (r < 0 && v) v->need_keyframe = 1;
    return r;
}

static int tb_vlayer_apply_param_sets(struct tb_video_layer *v, const uint8_t *payload, size_t len) {
    if (!v || !payload || len < 2) return -1;
    if (v->fmt && v->last_ps && v->last_ps_len == len && memcmp(v->last_ps, payload, len) == 0) {
        return 1;
    }

    int codec = payload[0];
    int count = payload[1];
    if ((codec != 1 && codec != 2) || count <= 0 || count > 16) return -1;

    const uint8_t *sets[16];
    size_t sizes[16];
    int profile_idc = 0;
    size_t off = 2;
    for (int i = 0; i < count; i++) {
        if (off + 4 > len) return -1;
        uint32_t sz = tb_vlayer_be32(payload + off);
        off += 4;
        if (sz == 0 || sz > len - off) return -1;
        sets[i] = payload + off;
        sizes[i] = sz;
        /* HEVC SPS (type 33): general_profile_idc is the low 5 bits after 2B header + 1B. */
        if (codec == 2 && sz > 3 && ((payload[off] >> 1) & 0x3f) == 33) {
            profile_idc = payload[off + 3] & 0x1f;
        }
        off += sz;
    }

    CMVideoFormatDescriptionRef fmt = NULL;
    OSStatus status;
    if (codec == 2) {
        status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
            kCFAllocatorDefault, (size_t)count, sets, sizes, 4, NULL, &fmt);
    } else {
        status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
            kCFAllocatorDefault, (size_t)count, sets, sizes, 4, &fmt);
    }
    if (status != noErr || !fmt) {
        fprintf(stderr, "[vlayer] format description failed: %d\n", (int)status);
        return -1;
    }

    CMVideoDimensions dims = CMVideoFormatDescriptionGetDimensions(fmt);
    if (v->fmt && (dims.width != v->width || dims.height != v->height || codec != v->codec)) {
        [v->layer flush];
        v->stats.flushes++;
    }
    if (v->fmt) CFRelease(v->fmt);
    v->fmt = fmt;
    v->codec = codec;
    v->profile_idc = profile_idc;
    v->width = dims.width;
    v->height = dims.height;
    v->need_keyframe = 1;

    uint8_t *copy = realloc(v->last_ps, len);
    if (copy) {
        memcpy(copy, payload, len);
        v->last_ps = copy;
        v->last_ps_len = len;
    }
    fprintf(stderr, "[vlayer] format %s %dx%d%s\n", codec == 2 ? "HEVC" : "H.264", v->width, v->height,
            profile_idc == 2 ? " Main10" : (profile_idc == 1 ? " Main" : ""));
    return 0;
}

int tb_vlayer_enqueue(struct tb_video_layer *v, const uint8_t *avcc, size_t len) {
    if (!v || !v->fmt || !avcc || len < 5) return 0;

    if (v->layer.status == AVQueuedSampleBufferRenderingStatusFailed) {
        NSError *error = v->layer.error;
        fprintf(stderr, "[vlayer] layer failed: %s\n",
                error ? error.localizedDescription.UTF8String : "unknown");
        [v->layer flush];
        v->stats.flushes++;
        v->need_keyframe = 1;
        v->frames_since_failure = 0;
        if (++v->failures > TB_VLAYER_MAX_FAILURES) return -1;
    }

    int keyframe = tb_vlayer_is_keyframe(v->codec, avcc, len);
    if (v->need_keyframe && !keyframe) {
        v->stats.dropped_wait_key++;
        return 0;
    }
    if (!v->layer.readyForMoreMediaData) {
        if (!keyframe) {
            /* Decoder backlog: skip to the next keyframe instead of building latency. */
            v->stats.dropped_not_ready++;
            v->need_keyframe = 1;
            return 0;
        }
        [v->layer flush];
        v->stats.flushes++;
    }

    CMBlockBufferRef block = NULL;
    OSStatus status = CMBlockBufferCreateWithMemoryBlock(
        kCFAllocatorDefault, NULL, len, kCFAllocatorDefault, NULL, 0, len,
        kCMBlockBufferAssureMemoryNowFlag, &block);
    if (status != kCMBlockBufferNoErr || !block) return 0;
    status = CMBlockBufferReplaceDataBytes(avcc, block, 0, len);
    if (status != kCMBlockBufferNoErr) {
        CFRelease(block);
        return 0;
    }

    CMSampleBufferRef sample = NULL;
    const size_t sample_size = len;
    status = CMSampleBufferCreateReady(kCFAllocatorDefault, block, v->fmt,
                                       1, 0, NULL, 1, &sample_size, &sample);
    CFRelease(block);
    if (status != noErr || !sample) return 0;

    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sample, true);
    if (attachments && CFArrayGetCount(attachments) > 0) {
        CFMutableDictionaryRef dict = (CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
        CFDictionarySetValue(dict, kCMSampleAttachmentKey_DisplayImmediately, kCFBooleanTrue);
        CFDictionarySetValue(dict, kCMSampleAttachmentKey_NotSync, keyframe ? kCFBooleanFalse : kCFBooleanTrue);
    }

    [v->layer enqueueSampleBuffer:sample];
    CFRelease(sample);

    v->need_keyframe = 0;
    if (++v->frames_since_failure > TB_VLAYER_HEALTHY_FRAMES) v->failures = 0;
    v->stats.enqueued++;
    return 1;
}

void tb_vlayer_set_visible(struct tb_video_layer *v, int visible) {
    if (!v) return;
    BOOL hidden = visible ? NO : YES;
    if (v->view.hidden == hidden) return;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    v->view.hidden = hidden;
    /* Avoid compositing a full-screen translucent overlay over the video. */
    v->overlay.hidden = visible ? YES : NO;
    [CATransaction commit];
}

void tb_vlayer_set_cursor_image(struct tb_video_layer *v, const uint8_t *argb,
                                int dim, int hotspot) {
    if (!v || !argb || dim <= 0) return;
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CFDataRef data = CFDataCreate(kCFAllocatorDefault, argb, (CFIndex)dim * dim * 4);
    CGDataProviderRef provider = data ? CGDataProviderCreateWithCFData(data) : NULL;
    CGImageRef image = provider
        ? CGImageCreate((size_t)dim, (size_t)dim, 8, 32, (size_t)dim * 4, space,
                        kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little,
                        provider, NULL, false, kCGRenderingIntentDefault)
        : NULL;
    if (image) {
        CGFloat scale = v->view.window.backingScaleFactor > 0 ? v->view.window.backingScaleFactor : 1.0;
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        v->cursor.contents = (__bridge id)image;
        v->cursor.contentsScale = scale;
        v->cursor.bounds = CGRectMake(0, 0, dim / scale, dim / scale);
        /* Unflipped coordinates; anchor on the hotspot. */
        v->cursor.anchorPoint = CGPointMake((CGFloat)hotspot / dim, 1.0 - (CGFloat)hotspot / dim);
        [CATransaction commit];
        v->cursor_dim = dim;
        v->cursor_hotspot = hotspot;
        v->cursor_image_mode = 0;
        CGImageRelease(image);
    }
    if (provider) CGDataProviderRelease(provider);
    if (data) CFRelease(data);
    CGColorSpaceRelease(space);
}

void tb_vlayer_set_cursor(struct tb_video_layer *v, double x_norm, double y_norm, int visible,
                          int source_w, int large) {
    if (!v) return;
    v->cursor_x = x_norm;
    v->cursor_y = y_norm;
    v->cursor_visible = visible;
    v->cursor_source_w = source_w;
    v->cursor_large = large;
    CGRect bounds = v->root.bounds;
    v->cursor_bounds = bounds.size;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    /* source_w of 1 is the display's "no cursor yet" placeholder. */
    if (v->cursor_image_mode && source_w > 1) {
        /* Source pixels map to view points by the same ratio as the video. */
        double scale = bounds.size.width / source_w * (large ? 1.8 : 1.0);
        if (scale != v->cursor_image_scale) {
            v->cursor_image_scale = scale;
            v->cursor.bounds = CGRectMake(0, 0, v->cursor_image_size.width * scale,
                                          v->cursor_image_size.height * scale);
        }
    }
    v->cursor.hidden = (visible && v->cursor_dim > 0) ? NO : YES;
    v->cursor.position = CGPointMake(x_norm * bounds.size.width,
                                     (1.0 - y_norm) * bounds.size.height);
    [CATransaction commit];
}

void tb_vlayer_refresh_cursor(struct tb_video_layer *v) {
    if (!v) return;
    /* Bounds changed (e.g. fullscreen): re-apply the last position. */
    if (CGSizeEqualToSize(v->root.bounds.size, v->cursor_bounds)) return;
    tb_vlayer_set_cursor(v, v->cursor_x, v->cursor_y, v->cursor_visible,
                         v->cursor_source_w, v->cursor_large);
}

int tb_vlayer_set_cursor_png(struct tb_video_layer *v, const uint8_t *png, size_t len,
                             int hotspot_x, int hotspot_y, int width, int height) {
    if (!v || !png || len == 0 || width <= 0 || height <= 0) return -1;
    CFDataRef data = CFDataCreate(kCFAllocatorDefault, png, (CFIndex)len);
    if (!data) return -1;
    CGImageSourceRef source = CGImageSourceCreateWithData(data, NULL);
    CGImageRef image = source ? CGImageSourceCreateImageAtIndex(source, 0, NULL) : NULL;
    if (source) CFRelease(source);
    CFRelease(data);
    if (!image) return -1;

    CGFloat backing = v->view.window.backingScaleFactor > 0 ? v->view.window.backingScaleFactor : 1.0;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    v->cursor.contents = (__bridge id)image;
    v->cursor.contentsScale = backing;
    /* Unflipped coordinates; anchor on the hotspot (top-left origin in the source). */
    v->cursor.anchorPoint = CGPointMake((CGFloat)hotspot_x / width, 1.0 - (CGFloat)hotspot_y / height);
    [CATransaction commit];
    CGImageRelease(image);

    v->cursor_image_mode = 1;
    v->cursor_image_size = CGSizeMake(width, height);
    v->cursor_image_scale = 0;
    v->cursor_dim = width;
    tb_vlayer_set_cursor(v, v->cursor_x, v->cursor_y, v->cursor_visible,
                         v->cursor_source_w, v->cursor_large);
    return 0;
}

int tb_vlayer_supports_main10_hw(void) {
    static int cached = -1;
    if (cached >= 0) return cached;
    /* 4096x2304 HEVC Main10 VPS/SPS/PPS; probes for a hardware decoder. */
    static const uint8_t vps[] = {
        0x40, 0x01, 0x0c, 0x01, 0xff, 0xff, 0x02, 0x20, 0x00, 0x00, 0x03, 0x00, 0xb0, 0x00, 0x00, 0x03,
        0x00, 0x00, 0x03, 0x00, 0xba, 0x17, 0x02, 0x40
    };
    static const uint8_t sps[] = {
        0x42, 0x01, 0x01, 0x02, 0x20, 0x00, 0x00, 0x03, 0x00, 0xb0, 0x00, 0x00, 0x03, 0x00, 0x00, 0x03,
        0x00, 0xba, 0xa0, 0x00, 0x80, 0x08, 0x00, 0x90, 0x13, 0x62, 0x05, 0xee, 0x45, 0x91, 0x4b, 0xff,
        0x2e, 0x7f, 0x13, 0xfa, 0x20
    };
    static const uint8_t pps[] = { 0x44, 0x01, 0xc0, 0x72, 0xf4, 0x53, 0x64 };
    const uint8_t *sets[] = { vps, sps, pps };
    const size_t sizes[] = { sizeof(vps), sizeof(sps), sizeof(pps) };

    cached = 0;
    CMVideoFormatDescriptionRef fmt = NULL;
    if (CMVideoFormatDescriptionCreateFromHEVCParameterSets(kCFAllocatorDefault, 3, sets, sizes, 4, NULL, &fmt) != noErr) {
        return cached;
    }
    NSDictionary *spec = @{ (__bridge NSString *)kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: @YES };
    VTDecompressionSessionRef session = NULL;
    if (VTDecompressionSessionCreate(kCFAllocatorDefault, fmt, (__bridge CFDictionaryRef)spec,
                                     NULL, NULL, &session) == noErr && session) {
        cached = 1;
        VTDecompressionSessionInvalidate(session);
        CFRelease(session);
    }
    CFRelease(fmt);
    fprintf(stderr, "[vlayer] hardware HEVC Main10 decode: %s\n", cached ? "yes" : "no");
    return cached;
}

int tb_vlayer_is_main10(struct tb_video_layer *v) {
    return v && v->codec == 2 && v->profile_idc == 2 ? 1 : 0;
}

int tb_vlayer_has_format(struct tb_video_layer *v) {
    return v && v->fmt ? 1 : 0;
}

void tb_vlayer_reset(struct tb_video_layer *v) {
    if (!v) return;
    v->cursor.hidden = YES;
    v->cursor_image_mode = 0;
    v->cursor_dim = 0;
    [v->layer flushAndRemoveImage];
    if (v->fmt) {
        CFRelease(v->fmt);
        v->fmt = NULL;
    }
    free(v->last_ps);
    v->last_ps = NULL;
    v->last_ps_len = 0;
    v->width = 0;
    v->height = 0;
    v->profile_idc = 0;
    v->need_keyframe = 1;
    v->failures = 0;
    v->frames_since_failure = 0;
    tb_vlayer_set_visible(v, 0);
}

void tb_vlayer_get_size(struct tb_video_layer *v, int *w, int *h) {
    if (w) *w = v ? v->width : 0;
    if (h) *h = v ? v->height : 0;
}

void tb_vlayer_take_stats(struct tb_video_layer *v, struct tb_video_layer_stats *out) {
    if (!v || !out) return;
    *out = v->stats;
    memset(&v->stats, 0, sizeof(v->stats));
}

#pragma clang diagnostic pop
