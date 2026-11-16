# /// script
# requires-python = ">=3.11"
# dependencies = ["numpy", "opencv-python-headless", "pillow"]
# ///
"""Render a Screen-Studio-style video from raw.mp4 + cursor.jsonl.

Usage: uv run render.py RAW.mp4 CURSOR.jsonl OUT.mp4 --src-scale S
       uv run render.py RAW.mp4 CURSOR.jsonl RENDERED.mp4 --sheet SHEET.png

The camera zooms on hovers ("focus"), clicks and typing, pans from target to
target inside a shot, and is fully zoomed out whenever the page scrolls.
"""

import argparse
import functools
import json
import math
import os
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

import cv2
import numpy as np
from PIL import Image, ImageDraw, ImageFont

OUT_W, OUT_H, OUT_FPS = 1920, 1080, 60
MAX_ZOOM = 1.8
RAMP = 0.6          # seconds to zoom in or out
PAN = 0.7           # seconds to pan between targets inside one shot
LEAD = 0.7          # a shot starts zooming this long before its first target
HOLD = 1.4          # and ends this long after its last one
MIN_HOLD = 0.4      # a shot handing over to the next still holds its last target this long
MERGE_GAP = 3.0     # targets closer in time than this share a shot...
MERGE_DIST = 0.3    # ...unless they are farther apart than this (fraction of width)
PAD = 0.055         # backdrop padding, fraction of output width
RADIUS = 18
SUPERSAMPLE = 2     # warp at 2x output size, then area-downsample: no aliasing on 4K input
CURSOR_SIZE = 54    # drawn cursor's nominal size in logical px (system default is 24)
CURSOR_SPRING = 22  # cursor smoothing; higher follows the telemetry more tightly
CURSOR_THEME = Path("/usr/share/icons/Adwaita/cursors")
sys.path.insert(0, str(Path(__file__).resolve().parent))
import xcursor  # noqa: E402


@dataclass
class Shot:
    start: float
    end: float
    targets: list = field(default_factory=list)   # (t, x, y) in source pixels

    def zoom(self, width, max_zoom):
        """Deep enough to read, shallow enough that every target of the shot fits with margin."""
        xs = [x for _, x, _ in self.targets]
        return max(1.0, min(max_zoom, width / (max(xs) - min(xs) + 0.5 * width)))


def probe(path):
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-select_streams", "v:0",
         "-show_entries", "stream=width,height,r_frame_rate:format=duration",
         "-of", "json", path], check=True, capture_output=True, text=True).stdout
    info = json.loads(out)
    s = info["streams"][0]
    num, den = map(int, s["r_frame_rate"].split("/"))
    return s["width"], s["height"], num / den, float(info["format"]["duration"])


def load_events(path, duration):
    events = [json.loads(line) for line in open(path)]
    stop = next(e for e in events if e["kind"] == "stop")
    offset = stop["t"] - duration
    return [dict(e, t=e["t"] - offset) for e in events if e["kind"] != "stop"]


def plan_shots(events, width):
    shots, last = [], None
    for e in events:
        if e["kind"] == "scroll":
            # Never stay zoomed across a page scroll: be half zoomed out when it starts.
            if shots:
                shots[-1].end = min(shots[-1].end, e["t"] - RAMP / 2)
            last = None
            continue
        if e["kind"] not in ("down", "type", "focus"):
            continue
        hold = typing_end(e) - e["t"] + HOLD if e["kind"] == "type" else HOLD
        near = last and math.hypot(e["x"] - last["x"], e["y"] - last["y"]) < MERGE_DIST * width
        if near and e["t"] - last["t"] < MERGE_GAP:
            shots[-1].end = max(shots[-1].end, e["t"] + hold)
        else:
            start = e["t"] - LEAD
            if shots:  # hand over: the previous shot fades out as this one fades in
                handover = max(shots[-1].targets[-1][0] + MIN_HOLD, start)
                shots[-1].end = min(shots[-1].end, handover)
                start = max(start, shots[-1].end)
            shots.append(Shot(start, e["t"] + hold))
        shots[-1].targets.append((e["t"], e["x"], e["y"]))
        last = e
    return shots


def typing_end(e):
    """When the last character of a type event lands."""
    return e["t"] + e["lead"] + len(e["text"]) * e["delay"]


KEY_LATENCY = 0.12  # wtype's keys reach the app this much after they're sent (measured)
KEY_SYMBOLS = {"Return": "\u23ce", "Tab": "\u21e5", "BackSpace": "\u232b", "Escape": "esc",
               "space": " ", "Up": "\u2191", "Down": "\u2193", "Left": "\u2190", "Right": "\u2192"}


def keystroke_timeline(events):
    """(time, glyph) for every visible keystroke, in order."""
    out = []
    for e in events:
        if e["kind"] == "type":
            out += [(e["t"] + KEY_LATENCY + e["lead"] + i * e["delay"], ch)
                    for i, ch in enumerate(e["text"])]
        elif e["kind"] == "key":
            out.append((e["t"] + KEY_LATENCY, KEY_SYMBOLS.get(e["key"], e["key"])))
    return out


def keystroke_text(timeline, t, gap=1.5, linger=1.4):
    """Text to show at t and its opacity: the current burst of typing, faded after it ends."""
    shown = [(kt, ch) for kt, ch in timeline if kt <= t]
    if not shown or t - shown[-1][0] > linger + 0.2:
        return "", 0.0
    burst = [shown[-1]]
    for kt, ch in reversed(shown[:-1]):
        if burst[0][0] - kt > gap:
            break
        burst.insert(0, (kt, ch))
    text = "".join(ch for _, ch in burst)
    if len(text) > 90:
        text = "\u2026" + text[-89:]
    fade_in = min(1.0, (t - burst[0][0]) / 0.15)
    fade_out = min(1.0, max(0.0, (linger + 0.2 - (t - shown[-1][0])) / 0.2))
    return text, min(fade_in, fade_out)


def find_font(pattern, size):
    try:
        path = subprocess.run(["fc-match", "--format=%{file}", pattern],
                              capture_output=True, text=True, check=True).stdout
        return ImageFont.truetype(path, size)
    except (OSError, subprocess.CalledProcessError):
        return ImageFont.load_default(size)


def fit_font(font, text, max_width, min_size=18):
    """Shrink font until text fits max_width, so a whole command stays readable."""
    while font.getlength(text) > max_width and font.size > min_size:
        font = font.font_variant(size=font.size - 2)
    return font


@functools.lru_cache(maxsize=4)
def pill_patch(text, font, max_width):
    """Rasterized pill for text as float RGBA; typing changes it a few times a second, frames 60."""
    font = fit_font(font, text, max_width)
    left, top, right, bottom = font.getbbox(text)
    pad_x, pad_y = 28, 16
    pw, ph = right - left + 2 * pad_x, (bottom - top) + 2 * pad_y
    pill = Image.new("RGBA", (pw, ph), (0, 0, 0, 0))
    draw = ImageDraw.Draw(pill)
    draw.rounded_rectangle((0, 0, pw - 1, ph - 1), radius=ph // 2, fill=(20, 22, 30, 215))
    draw.text((pad_x - left, pad_y - top), text, font=font, fill=(255, 255, 255, 255))
    return np.asarray(pill).astype(np.float32) / 255


def draw_keystrokes(canvas, text, opacity, font, window, at_bottom=True):
    """Rounded dark pill with the typed text, centered inside the recorded window.

    window is (x, y, w, h) of the recording on the canvas. at_bottom=False puts it in
    the page area instead, above a docked DevTools panel it would otherwise cover.
    """
    if not text or opacity <= 0:
        return canvas
    wx, wy, ww, wh = window
    patch = pill_patch(text, font, ww - 120)
    ph, pw = patch.shape[:2]
    x0 = wx + (ww - pw) // 2
    y0 = wy + wh - ph - 24 if at_bottom else wy + int(wh * 0.5) - ph // 2
    if x0 < 0:
        patch, x0 = patch[:, -x0:], 0
    a = patch[..., 3:] * opacity
    region = canvas[y0:y0 + ph, x0:x0 + patch.shape[1]].astype(np.float32) / 255
    rgb = patch[..., 2::-1]  # RGBA -> BGR
    canvas[y0:y0 + ph, x0:x0 + patch.shape[1]] = ((rgb * a + region * (1 - a)) * 255 + 0.5).astype(np.uint8)
    return canvas


def smoothstep(u):
    u = min(1.0, max(0.0, u))
    return u * u * u * (u * (u * 6 - 15) + 10)


def shot_center(shot, t, w, h, zoom):
    """Camera target inside a shot: sits on each target, pans to the next as the cursor travels.

    Targets are clamped for the shot's final zoom. Easing from the frame center toward
    a target clamped that way stays inside the frame at every intermediate zoom (the
    edge limit w/2z is convex in the zoom amount), so the camera never meets the hard
    clamp in camera() mid-zoom, where it would kink its velocity.
    """
    def clamp(x, y):
        hw, hh = w / (2 * zoom), h / (2 * zoom)
        return min(max(x, hw), w - hw), min(max(y, hh), h - hh)
    _, x, y = shot.targets[0]
    x, y = clamp(x, y)
    for nt, nx, ny in shot.targets[1:]:
        nx, ny = clamp(nx, ny)
        u = smoothstep((t - (nt - PAN)) / PAN)
        x, y = x + (nx - x) * u, y + (ny - y) * u
    return x, y


def camera(t, shots, w, h, max_zoom):
    """Camera center and zoom at t. Shots whose ramps overlap are blended by weight, so
    handing over from one shot to the next never jumps."""
    total, sx, sy, sz = 0.0, 0.0, 0.0, 0.0
    for s in shots:
        a = min(smoothstep((t - s.start) / RAMP), 1 - smoothstep((t - s.end) / RAMP))
        if a <= 0:
            continue
        zoom = s.zoom(w, max_zoom)
        x, y = shot_center(s, t, w, h, zoom)
        total, sx, sy, sz = total + a, sx + a * x, sy + a * y, sz + a * zoom
    if total == 0:
        return w / 2, h / 2, 1.0
    amount = min(1.0, total)
    z = 1 + (sz / total - 1) * amount
    cx = w / 2 + (sx / total - w / 2) * amount
    cy = h / 2 + (sy / total - h / 2) * amount
    half_w, half_h = w / (2 * z), h / (2 * z)
    return min(max(cx, half_w), w - half_w), min(max(cy, half_h), h - half_h), z


def backdrop():
    yy, xx = np.mgrid[0:OUT_H, 0:OUT_W].astype(np.float32)
    u = (xx / OUT_W * 0.6 + yy / OUT_H * 0.4)[..., None]
    top = np.array([0x8a, 0x5a, 0x3b], np.float32)      # BGR, deep indigo
    bottom = np.array([0xd6, 0x8e, 0xc4], np.float32)   # BGR, soft violet
    return (top * (1 - u) + bottom * u).astype(np.uint8)


def rounded_mask(w, h, r):
    mask = np.zeros((h, w), np.uint8)
    cv2.rectangle(mask, (r, 0), (w - r, h), 255, -1)
    cv2.rectangle(mask, (0, r), (w, h - r), 255, -1)
    for cx, cy in ((r, r), (w - r - 1, r), (r, h - r - 1), (w - r - 1, h - r - 1)):
        cv2.circle(mask, (cx, cy), r, 255, -1, cv2.LINE_AA)
    return mask.astype(np.float32)[..., None] / 255


def click_ripples(view, clicks, t, cx, cy, scale, in_w, in_h):
    for c in clicks:
        age = t - c["t"]
        if 0 <= age < 0.5:
            px = int((c["x"] - cx) * scale + in_w / 2)
            py = int((c["y"] - cy) * scale + in_h / 2)
            radius = int(18 + 50 * smoothstep(age / 0.5))
            ring = view.copy()
            cv2.circle(ring, (px, py), radius, (245, 110, 76), 4, cv2.LINE_AA)
            alpha = 1 - age / 0.5
            view = cv2.addWeighted(ring, alpha, view, 1 - alpha, 0)
    return view


@dataclass
class Sprite:
    rgb: np.ndarray      # float32 HxWx3, premultiplied
    alpha: np.ndarray    # float32 HxWx1
    nominal: int         # Xcursor nominal size of this image
    hot: tuple


def load_sprite(name):
    w, h, xhot, yhot, pixels = xcursor.read_largest(CURSOR_THEME / name)
    bgra = np.frombuffer(pixels, np.uint8).reshape(h, w, 4).astype(np.float32) / 255
    return Sprite(bgra[..., :3].copy(), bgra[..., 3:].copy(), w, (xhot, yhot))


def cursor_path(events, n_frames, fps):
    """Cursor position at every output frame: telemetry interpolated, then spring-smoothed."""
    moves = [e for e in events if "x" in e]
    ts = np.array([e["t"] for e in moves])
    xs = np.array([e["x"] for e in moves], dtype=float)
    ys = np.array([e["y"] for e in moves], dtype=float)
    frame_t = np.arange(n_frames) / fps
    raw_x, raw_y = np.interp(frame_t, ts, xs), np.interp(frame_t, ts, ys)
    out = np.empty((n_frames, 2))
    pos, vel, dt = np.array([raw_x[0], raw_y[0]]), np.zeros(2), 1 / fps
    for i in range(n_frames):
        target = np.array([raw_x[i], raw_y[i]])
        for _ in range(4):  # substeps keep a stiff spring stable at 60 fps
            accel = CURSOR_SPRING ** 2 * (target - pos) - 2 * CURSOR_SPRING * vel
            vel = vel + accel * dt / 4
            pos = pos + vel * dt / 4
        out[i] = pos
    return out


def cursor_shapes(events, path, fps):
    """Shape per frame: a hand while the cursor is inside a hovered link's box, like the browser."""
    shapes = np.full(len(path), "default", dtype=object)
    scrolls = [int(e["t"] * fps) for e in events if e["kind"] == "scroll"]
    for f in (e for e in events if e["kind"] == "focus" and e.get("cursor") == "pointer" and "box" in e):
        i = int(f["t"] * fps)
        x0, y0, x1, y1 = f["box"]
        near = lambda k: x0 <= path[k][0] <= x1 and y0 <= path[k][1] <= y1
        # A scroll moves the page out from under a still cursor, so the hand ends there too.
        end = min([k for k in scrolls if k > i] + [len(path)])
        lo = i
        while lo > 0 and near(lo - 1):
            lo -= 1
        hi = i
        while hi < end - 1 and near(hi + 1):
            hi += 1
        shapes[lo:hi + 1] = "pointer"
    return shapes


def press_scale(t, clicks):
    """Cursor shrinks a little while the button is down, like a physical press."""
    s = 1.0
    for c in clicks:
        age = t - c["t"]
        if -0.05 <= age < 0.25:
            s = min(s, 1 - 0.15 * math.sin(math.pi * min(1, (age + 0.05) / 0.3)))
    return s


def motion_blur(rgb, alpha, vx, vy):
    """Smear the sprite along its per-frame motion, as a 180-degree shutter would."""
    length = 0.5 * math.hypot(vx, vy)
    if length < 1.5:
        return rgb, alpha, 0
    pad = math.ceil(length / 2) + 1
    size = 2 * pad + 1
    kernel = np.zeros((size, size), np.float32)
    ux, uy = vx / math.hypot(vx, vy), vy / math.hypot(vx, vy)
    cv2.line(kernel, (round(pad - ux * length / 2), round(pad - uy * length / 2)),
             (round(pad + ux * length / 2), round(pad + uy * length / 2)), 1.0, 1, cv2.LINE_AA)
    kernel /= kernel.sum()
    rgb = cv2.filter2D(cv2.copyMakeBorder(rgb, pad, pad, pad, pad, cv2.BORDER_CONSTANT), -1, kernel)
    alpha = cv2.filter2D(cv2.copyMakeBorder(alpha, pad, pad, pad, pad, cv2.BORDER_CONSTANT), -1, kernel)
    return rgb, alpha, pad


def draw_cursor(view, sprite, x, y, size_px, vx=0.0, vy=0.0):
    """Alpha-composite sprite with its hotspot at (x, y), scaled to size_px nominal, with a soft shadow.

    (vx, vy) is the cursor's motion this frame in view pixels, for motion blur.
    """
    k = size_px / sprite.nominal
    sw, sh = max(1, round(sprite.rgb.shape[1] * k)), max(1, round(sprite.rgb.shape[0] * k))
    rgb = cv2.resize(sprite.rgb, (sw, sh), interpolation=cv2.INTER_AREA)
    alpha = cv2.resize(sprite.alpha, (sw, sh), interpolation=cv2.INTER_AREA)
    rgb, alpha, pad = motion_blur(rgb, alpha, vx, vy)
    alpha = alpha[..., None]
    sh, sw = alpha.shape[:2]
    ox, oy = round(x - sprite.hot[0] * k) - pad, round(y - sprite.hot[1] * k) - pad
    blur = max(1.0, size_px / 14)
    shadow = cv2.GaussianBlur(alpha[..., 0], (0, 0), blur)[..., None] * 0.35
    off = max(1, round(size_px / 16))
    layers = [(ox + off, oy + 2 * off, np.zeros_like(rgb), shadow), (ox, oy, rgb, alpha)]
    h, w = view.shape[:2]
    for lx, ly, color, a in layers:
        x0, y0 = max(lx, 0), max(ly, 0)
        x1, y1 = min(lx + sw, w), min(ly + sh, h)
        if x0 >= x1 or y0 >= y1:
            continue
        c = color[y0 - ly:y1 - ly, x0 - lx:x1 - lx]
        al = a[y0 - ly:y1 - ly, x0 - lx:x1 - lx]
        under = view[y0:y1, x0:x1].astype(np.float32) / 255
        view[y0:y1, x0:x1] = ((c + under * (1 - al)) * 255 + 0.5).astype(np.uint8)
    return view


def content_start(events, shots, lead=0.5):
    """First moment worth showing: just before the first zoom or the first visible change."""
    marks = [s.start for s in shots] + [e["t"] for e in events if e["kind"] in ("scroll", "down")]
    return max(0.0, min(marks) - lead) if marks else 0.0


def content_end(events, shots, keys, tail=1.2):
    """Last moment worth showing: end of the last zoom-out, scroll, or keystroke, plus a short hold."""
    marks = [s.end + RAMP for s in shots]
    marks += [e["t"] + 1.2 for e in events if e["kind"] == "scroll"]  # smooth scroll settles
    marks += [kt + 0.8 for kt, _ in keys]
    return max(marks) + tail if marks else float("inf")


@dataclass
class Plan:
    """Everything the render and the sheet share: geometry, events, shots, trimmed span."""
    w: int
    h: int
    src_fps: float
    duration: float
    events: list
    shots: list
    keys: list
    t_start: float
    t_end: float


def plan(raw, cursor):
    w, h, src_fps, duration = probe(raw)
    events = load_events(cursor, duration)
    shots = plan_shots(events, w)
    keys = keystroke_timeline(events)
    t_start = content_start(events, shots)
    return Plan(w, h, src_fps, duration, events, shots, keys, t_start,
                min(duration, content_end(events, shots, keys)))


def render(raw, cursor, out, src_scale, draw_pointer=True):
    p = plan(raw, cursor)
    w, h = p.w, p.h
    clicks = [e for e in p.events if e["kind"] == "down"]
    # A still take (reviewer mode) keeps the whole window: address bar and DevTools
    # are the point, and any zoom worth having would crop one of them.
    still = any(e["kind"] == "camera" and e["mode"] == "still" for e in p.events)
    max_zoom = 1.0 if still else MAX_ZOOM
    n_frames = int((p.t_end - p.t_start) * OUT_FPS)
    key_font = find_font("DejaVu Sans Mono:bold", 30)
    if draw_pointer:
        sprites = {name: load_sprite(name) for name in ("default", "pointer")}
        # Indexed by absolute frame (t * fps), so it covers the whole take, trimmed or not.
        path = cursor_path(p.events, int(p.duration * OUT_FPS) + 1, OUT_FPS)
        shapes = cursor_shapes(p.events, path, OUT_FPS)

    pad = int(OUT_W * PAD)
    in_w = OUT_W - 2 * pad
    in_h = round(in_w * h / w)
    ox, oy = pad, (OUT_H - in_h) // 2
    mask = rounded_mask(in_w, in_h, RADIUS)
    base = backdrop()
    shadow = np.zeros((OUT_H, OUT_W), np.float32)
    cv2.rectangle(shadow, (ox, oy + 14), (ox + in_w, oy + in_h + 14), 1.0, -1)
    shadow = cv2.GaussianBlur(shadow, (0, 0), 28)[..., None] * 0.45
    base = (base * (1 - shadow)).astype(np.uint8)

    decoder = subprocess.Popen(["ffmpeg", "-v", "error", "-ss", f"{p.t_start:.3f}", "-i", raw,
                                "-f", "rawvideo", "-pix_fmt", "bgr24", "-"], stdout=subprocess.PIPE)
    # Encode to a side file and rename on success, so a failed render never
    # replaces a good video that is already there.
    root, ext = os.path.splitext(out)
    partial = f"{root}.partial{ext}"
    encoder = subprocess.Popen(["ffmpeg", "-v", "error", "-y", "-f", "rawvideo",
                                "-pix_fmt", "bgr24", "-s", f"{OUT_W}x{OUT_H}", "-r", str(OUT_FPS),
                                "-i", "-", "-an", "-c:v", "libx264", "-preset", "slow", "-crf", "18",
                                "-pix_fmt", "yuv420p", "-movflags", "+faststart", partial],
                               stdin=subprocess.PIPE)
    assert decoder.stdout and encoder.stdin
    frame_bytes = w * h * 3
    src_index, frame = -1, None
    ss_w, ss_h = in_w * SUPERSAMPLE, in_h * SUPERSAMPLE
    try:
        for i in range(n_frames):
            t = p.t_start + i / OUT_FPS
            want = min(int((t - p.t_start) * p.src_fps + 1e-6),
                       int((p.duration - p.t_start) * p.src_fps) - 1)
            while src_index < want:
                buf = decoder.stdout.read(frame_bytes)
                if len(buf) < frame_bytes:
                    break
                frame = np.frombuffer(buf, np.uint8).reshape(h, w, 3)
                src_index += 1
            if frame is None or src_index < want - 1:
                raise SystemExit(f"{raw}: ran out of frames at {t:.2f}s; is the take truncated?")
            cx, cy, z = camera(t, p.shots, w, h, max_zoom)
            scale = ss_w / (w / z)
            m = np.array([[scale, 0, ss_w / 2 - cx * scale], [0, scale, ss_h / 2 - cy * scale]],
                         np.float32)
            view = cv2.warpAffine(frame, m, (ss_w, ss_h), flags=cv2.INTER_LINEAR,
                                  borderMode=cv2.BORDER_REPLICATE)
            view = cv2.resize(view, (in_w, in_h), interpolation=cv2.INTER_AREA)
            view = click_ripples(view, clicks, t, cx, cy, scale / SUPERSAMPLE, in_w, in_h)
            if draw_pointer:
                view_scale = scale / SUPERSAMPLE
                k = min(round(t * OUT_FPS), len(path) - 1)
                px = (path[k][0] - cx) * view_scale + in_w / 2
                py = (path[k][1] - cy) * view_scale + in_h / 2
                size = CURSOR_SIZE * src_scale * view_scale * press_scale(t, clicks)
                prev = path[max(k - 1, 0)]
                vx, vy = (path[k][0] - prev[0]) * view_scale, (path[k][1] - prev[1]) * view_scale
                view = draw_cursor(view, sprites[shapes[k]], px, py, size, vx, vy)

            canvas = base.copy()
            region = canvas[oy:oy + in_h, ox:ox + in_w]
            canvas[oy:oy + in_h, ox:ox + in_w] = (view * mask + region * (1 - mask)).astype(np.uint8)
            canvas = draw_keystrokes(canvas, *keystroke_text(p.keys, t), key_font, (ox, oy, in_w, in_h),
                                     at_bottom=not still)
            encoder.stdin.write(canvas.tobytes())
    except BrokenPipeError:
        pass  # the encoder died; its exit status below says why
    finally:
        decoder.kill()  # it may still hold unread frames
        decoder.wait()
        try:
            encoder.stdin.close()
        except BrokenPipeError:
            pass
        status = encoder.wait()
        if status != 0 or sys.exc_info()[0] is not None:
            if os.path.exists(partial):
                os.remove(partial)
    if status != 0:
        raise SystemExit(f"ffmpeg failed to encode {out} (exit {status}); see its error above")
    os.replace(partial, out)


def sheet(raw, cursor, video, png, columns=3):
    """Contact sheet of the rendered video at every hover, click, typing burst and scroll."""
    p = plan(raw, cursor)
    settle = {"focus": 0.4, "down": 0.3, "type": 1.0, "scroll": 0.3}
    moments = [(e["t"] - p.t_start + settle[e["kind"]], e["kind"])
               for e in p.events if e["kind"] in settle]
    tiles = []
    for t, kind in moments:
        if not 0 <= t < p.t_end - p.t_start:
            continue
        frame = subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-ss", f"{t:.3f}", "-i", video,
                                "-frames:v", "1", "-vf", "scale=960:540", "-f", "rawvideo",
                                "-pix_fmt", "bgr24", "-"], check=True, capture_output=True).stdout
        tile = np.frombuffer(frame, np.uint8).reshape(540, 960, 3).copy()
        cv2.putText(tile, f"{t:.2f}s {kind}", (12, 34), cv2.FONT_HERSHEY_SIMPLEX, 1.0, (0, 0, 0), 5)
        cv2.putText(tile, f"{t:.2f}s {kind}", (12, 34), cv2.FONT_HERSHEY_SIMPLEX, 1.0, (0, 255, 255), 2)
        tiles.append(tile)
    if not tiles:
        raise SystemExit(f"{cursor}: no hover, click, typing or scroll events to put on a sheet")
    tiles += [np.zeros_like(tiles[0])] * (-len(tiles) % columns)
    rows = [np.hstack(tiles[i:i + columns]) for i in range(0, len(tiles), columns)]
    if not cv2.imwrite(png, np.vstack(rows)):
        raise SystemExit(f"could not write {png}")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("raw")
    ap.add_argument("cursor")
    ap.add_argument("out", help="video to write, or with --sheet the rendered video to read")
    ap.add_argument("--src-scale", type=float,
                    help="capture pixels per logical pixel (headless-sway --scale); needed to render")
    ap.add_argument("--sheet", metavar="PNG", help="write a contact sheet of OUT instead of rendering")
    args = ap.parse_args()
    if args.sheet:
        sheet(args.raw, args.cursor, args.out, args.sheet)
    elif args.src_scale is None:
        ap.error("--src-scale is required to render")
    else:
        render(args.raw, args.cursor, args.out, args.src_scale)
