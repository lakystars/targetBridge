Fallbacks and switches
======================

TargetBridge prefers the fastest path each Mac supports and falls back
automatically when that path fails. This page lists what falls back, how to
see the current state, and how to override it.

Sender (Settings)
-----------------

| Setting | Default | Effect |
|---|---|---|
| Low-latency cursor on receiver | On | The receiver draws the cursor from position packets, so it skips encode latency. Turn off to keep every native cursor shape inside the video. |
| 10-bit color (HEVC Main10) | On | Extended-range capture with 10-bit HEVC to receivers that advertise Main10. Turn off to force 8-bit. |

The guided configuration check shows **Color depth**: whether 10-bit is active
and, if not, why (setting, receiver support, preset or source, or a fallback).

Automatic sender fallbacks:

- 10-bit is used only for HEVC presets in Extended Desktop on macOS 15+ with
  Apple Silicon, and only when the receiver advertises Main10. Mirror mode
  stays 8-bit because it captures the physical (possibly HDR) display.
- If extended-range capture is rejected, capture restarts in 8-bit.
- If 10-bit capture produces no first frame, or stalls twice, the connection
  continues in 8-bit. The next connection tries 10-bit again.
- If the receiver asks to renegotiate (for example after turning Main10 off),
  the sender reconnects once automatically.
- If a remembered display mode no longer applies, the next best HiDPI mode is
  used and the remembered mode is cleared.

Receiver (idle screen keys)
---------------------------

The idle screen explains the current video output and 10-bit state.
10-bit is used only when both the Sender setting and the Receiver allow it.

| Key | Effect |
|---|---|
| L | Cycle the receiver language. |
| V | Switch between the video layer (default) and the compatibility path (FFmpeg + OpenGL). |
| M | Turn 10-bit color off or on, including after an automatic opt-out. Applies from the next connection. |

Automatic receiver fallbacks:

- If the video layer cannot be created, the FFmpeg path is used.
- If the video layer fails repeatedly on an 8-bit stream, the session
  continues on FFmpeg. After failures in two sessions, the next launch starts
  in compatibility mode; a healthy session or **V** resets this.
- If this Mac cannot decode the Main10 stream in hardware, or cannot keep up,
  10-bit is turned off automatically and the sender reconnects in 8-bit.
  **M** turns it back on.
- If a cursor sprite cannot be drawn, a built-in arrow is used.

Settings are stored in
`~/Library/Application Support/TargetBridge Receiver/settings.json`:

```json
{
  "language": "auto",
  "senderLanguage": "ko",
  "videoLayer": "on",
  "videoLayerFailures": "0",
  "main10": "on"
}
```

`main10` is `on`, `off` (turned off with **M**) or `auto-off` (turned off
after this Mac failed to play it).

Environment variables (advanced)
--------------------------------

These override the settings above when the app is started from Terminal.
They are not passed through `open -a` launch agents.

| Variable | App | Values | Effect |
|---|---|---|---|
| `TB_RECEIVER_VIDEO_LAYER` | Receiver | `0` / `1` | Force the compatibility path or the video layer. |
| `TB_RECEIVER_RENDER_DRIVER` | Receiver | `opengl`, `metal` | Force the SDL renderer. |
| `TB_RECEIVER_TIMING` | Receiver | `1` | Log per-second stage timings. |
| `TB_HEVC_10BIT` | Sender | `0` | Disable 10-bit capture and Main10. |
| `MPVP` | Sender | integer | Override the pending video packet limit. |
