# /// script
# requires-python = ">=3.11"
# dependencies = ["numpy", "opencv-python-headless", "pillow"]
# ///
"""Render a synthetic take and check the output format and where the camera points.

Usage: uv run test_render.py
"""

import json
import subprocess
import sys
import tempfile
from pathlib import Path

import cv2
import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import render  # noqa: E402

W, H, FPS, SECONDS, SCALE = 2880, 1620, 60, 6, 1.5
TARGET = (2000, 1200)        # red square center, source pixels
FOCUS_T = 2.0


def make_take(work):
    raw = work / "raw.mp4"
    x, y = TARGET[0] - 40, TARGET[1] - 40
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "lavfi",
                    "-i", f"color=c=0x202830:s={W}x{H}:r={FPS}:d={SECONDS}",
                    "-vf", f"drawbox=x={x}:y={y}:w=80:h=80:color=red:t=fill",
                    "-c:v", "libx264", "-preset", "ultrafast", "-qp", "0", str(raw)], check=True)
    events = []
    for i in range(61):  # center to target over the first second
        u = i / 60
        events.append({"t": u, "x": W / 2 + (TARGET[0] - W / 2) * u,
                       "y": H / 2 + (TARGET[1] - H / 2) * u, "kind": "move"})
    events.append({"t": FOCUS_T, "x": TARGET[0], "y": TARGET[1], "kind": "focus",
                   "cursor": "pointer", "box": [TARGET[0] - 40, TARGET[1] - 40,
                                                TARGET[0] + 40, TARGET[1] + 40]})
    events.append({"t": SECONDS, "kind": "stop"})
    cursor = work / "cursor.jsonl"
    cursor.write_text("".join(json.dumps(e) + "\n" for e in events))
    return raw, cursor


def frame_at(video, t):
    out = subprocess.run(["ffmpeg", "-v", "error", "-ss", str(t), "-i", str(video),
                          "-frames:v", "1", "-f", "rawvideo", "-pix_fmt", "bgr24", "-"],
                         check=True, capture_output=True).stdout
    return np.frombuffer(out, np.uint8).reshape(render.OUT_H, render.OUT_W, 3)


def red_centroid(frame):
    b, g, r = (frame[..., i].astype(int) for i in range(3))
    ys, xs = np.nonzero((r > 180) & (g < 80) & (b < 80))
    return xs.mean(), ys.mean(), len(xs)


def expected_position(t):
    """Where the square should land, from the renderer's own camera and layout math."""
    shots = render.plan_shots(render.load_events(CURSOR_EVENTS, SECONDS), W)
    cx, cy, z = render.camera(t, shots, W, H, render.MAX_ZOOM)
    pad = int(render.OUT_W * render.PAD)
    in_w = render.OUT_W - 2 * pad
    in_h = round(in_w * H / W)
    scale = in_w / (W / z)
    return (pad + in_w / 2 + (TARGET[0] - cx) * scale,
            (render.OUT_H - in_h) // 2 + in_h / 2 + (TARGET[1] - cy) * scale, z)


def check(name, ok, detail):
    print(f"{'PASS' if ok else 'FAIL'}  {name}: {detail}")
    return ok


def camera_has_no_kink_near_edge():
    """A target at the frame edge used to hit the hard clamp mid-zoom and kink the pan."""
    shot = render.Shot(1.0, 3.0, [(1.5, 60.0, 1500.0)])  # far left, near the bottom
    xs = [render.camera(1.0 + i / 60, [shot], W, H, render.MAX_ZOOM)[0] for i in range(60)]
    vel = [b - a for a, b in zip(xs, xs[1:])]
    jerk = max(abs(b - a) for a, b in zip(vel, vel[1:]))
    # A quintic smoothstep over n frames peaks at 10/sqrt(3) * distance / n^2 per frame.
    # Anything clearly above that is a kink, not easing.
    n = render.RAMP * 60
    bound = 1.1 * (10 / 3 ** 0.5) * abs(xs[-1] - xs[0]) / n ** 2
    return check("no camera kink at the frame edge", jerk < bound,
                 f"max velocity change {jerk:.2f} px/frame, smooth easing allows {bound:.2f}")


def camera_hands_over_without_jump():
    """Two far-apart shots whose ramps overlap used to swap targets in a single frame."""
    a = render.Shot(1.0, 3.0, [(1.7, 700.0, 800.0)])
    b = render.Shot(2.5, 5.0, [(3.2, 2200.0, 800.0)])
    cams = [render.camera(1.0 + i / 60, [a, b], W, H, render.MAX_ZOOM) for i in range(240)]
    step = max(abs(q[0] - p[0]) for p, q in zip(cams, cams[1:]))
    zoom_step = max(abs(q[2] - p[2]) for p, q in zip(cams, cams[1:]))
    # An eased crossfade over one ramp peaks near 1.875 * distance / ramp frames.
    bound = 1.3 * 1.875 * 1500 / (render.RAMP * 60)
    return check("no camera jump between overlapping shots", step < bound and zoom_step < 0.05,
                 f"largest per-frame move {step:.0f} px (smooth allows {bound:.0f}), zoom step {zoom_step:.3f}")


def far_target_soon_after_is_centered():
    """A far target hovered right after another used to park the camera halfway between them."""
    events = [{"t": 1.0, "x": 500.0, "y": 800.0, "kind": "focus"},
              {"t": 2.0, "x": 2400.0, "y": 800.0, "kind": "focus"}]
    cx, _, z = render.camera(2.6, render.plan_shots(events, W), W, H, render.MAX_ZOOM)
    edge = W - W / (2 * render.MAX_ZOOM)  # the target is clamped so the view stays in frame
    return check("far target soon after another is centered", abs(cx - edge) < 40 and z > 1.7,
                 f"camera x {cx:.0f}, expected {edge:.0f}, zoom {z:.2f}")


def brief_hover_is_held_before_handover():
    """A zero-dwell hover followed quickly by a far target used to be left the moment it was reached."""
    events = [{"t": 1.0, "x": 900.0, "y": 800.0, "kind": "focus"},
              {"t": 1.7, "x": 2100.0, "y": 800.0, "kind": "focus"}]
    cx, _, _ = render.camera(1.2, render.plan_shots(events, W), W, H, render.MAX_ZOOM)
    return check("brief hover held before handing over", abs(cx - 900) < 40,
                 f"camera x {cx:.0f} at 0.2 s after the hover, target 900")


def failed_render_keeps_previous_video(work, raw, cursor, good):
    """A truncated take must fail loudly and leave an existing render untouched."""
    # Index first, then cut the bytes: the header still promises the full length but
    # the frames stop halfway, like a recorder killed mid-take.
    short = work / "short.mp4"
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", str(raw), "-c", "copy",
                    "-movflags", "+faststart", str(short)], check=True)
    with open(short, "r+b") as f:
        f.truncate(short.stat().st_size // 2)
    before = good.read_bytes()
    try:
        render.render(str(short), str(cursor), str(good), SCALE, draw_pointer=False)
        failed = False
    except SystemExit:
        failed = True
    return check("failed render keeps the previous video",
                 failed and good.read_bytes() == before and not (work / "out.partial.mp4").exists(),
                 f"render failed: {failed}, previous video intact: {good.read_bytes() == before}")


def still_take_never_zooms(work, raw, cursor):
    """A take logged with camera="still" (reviewer mode) keeps the whole window in view."""
    still = work / "cursor-still.jsonl"
    still.write_text('{"t": 0.0, "kind": "camera", "mode": "still"}\n' + cursor.read_text())
    out = work / "still.mp4"
    render.render(str(raw), str(still), str(out), SCALE, draw_pointer=False)
    events = render.load_events(still, SECONDS)
    shots = render.plan_shots(events, W)
    t_start = render.content_start(events, shots)
    t = FOCUS_T + 0.5
    cx, cy, z = render.camera(t, shots, W, H, 1.0)
    pad = int(render.OUT_W * render.PAD)
    in_w = render.OUT_W - 2 * pad
    in_h = round(in_w * H / W)
    scale = in_w / (W / z)
    ex = pad + in_w / 2 + (TARGET[0] - cx) * scale
    ey = (render.OUT_H - in_h) // 2 + in_h / 2 + (TARGET[1] - cy) * scale
    x, y, _ = red_centroid(frame_at(out, t - t_start))
    return check("still take never zooms", z == 1.0 and abs(x - ex) < 6 and abs(y - ey) < 6,
                 f"square at ({x:.0f},{y:.0f}) expected full-view ({ex:.0f},{ey:.0f})")


def main():
    global CURSOR_EVENTS
    with tempfile.TemporaryDirectory() as tmp:
        work = Path(tmp)
        raw, cursor = make_take(work)
        CURSOR_EVENTS = cursor
        out = work / "out.mp4"
        # No drawn cursor: it sits on the target and would skew the square's centroid.
        render.render(str(raw), str(cursor), str(out), SCALE, draw_pointer=False)

        probe = json.loads(subprocess.run(
            ["ffprobe", "-v", "error", "-show_entries",
             "stream=codec_type,width,height,r_frame_rate,nb_frames", "-of", "json", str(out)],
            check=True, capture_output=True, text=True).stdout)["streams"]
        results = [camera_has_no_kink_near_edge(), camera_hands_over_without_jump(),
            far_target_soon_after_is_centered(), brief_hover_is_held_before_handover(),
            check("video only", [s["codec_type"] for s in probe] == ["video"], probe),
            check("1920x1080", (probe[0]["width"], probe[0]["height"]) == (1920, 1080), probe[0]),
            check("60 fps", probe[0]["r_frame_rate"] == "60/1", probe[0]["r_frame_rate"]),
            # The tail after the last zoom-out is trimmed, so the video ends early.
            check("tail trimmed", int(probe[0]["nb_frames"]) < SECONDS * FPS, probe[0]["nb_frames"]),
        ]
        events = render.load_events(cursor, SECONDS)
        t_start = render.content_start(events, render.plan_shots(events, W))
        results.append(check("lead-in trimmed", 0 < t_start < 1.3, f"starts at {t_start:.2f}s"))
        zoomed_t = FOCUS_T + 0.5  # take time; the output starts at t_start
        ex, ey, z = expected_position(zoomed_t)
        x, y, n = red_centroid(frame_at(out, zoomed_t - t_start))
        results.append(check("zoomed in on target", z > 1.79,
                             f"zoom {z:.2f} at t={zoomed_t}"))
        results.append(check("target where the camera says", abs(x - ex) < 6 and abs(y - ey) < 6,
                             f"found ({x:.0f},{y:.0f}) expected ({ex:.0f},{ey:.0f}), {n} px"))
        _, _, z_end = expected_position(t_start + int(probe[0]["nb_frames"]) / FPS - 0.05)
        results.append(check("zoomed out after the shot", z_end < 1.01, f"zoom {z_end:.2f}"))

        # The sheet's first tile is the hover; it must come from the trimmed render's timeline.
        png = work / "sheet.png"
        render.sheet(str(raw), str(cursor), str(out), str(png))
        tile = cv2.imread(str(png))[:540, :960]
        sx, sy, _ = red_centroid(cv2.resize(tile, (1920, 1080)))
        hx, hy, _ = expected_position(FOCUS_T + 0.4)
        results.append(still_take_never_zooms(work, raw, cursor))
        results.append(failed_render_keeps_previous_video(work, raw, cursor, out))
        results.append(check("sheet shows the hover moment", abs(sx - hx) < 12 and abs(sy - hy) < 12,
                             f"square at ({sx:.0f},{sy:.0f}) expected ({hx:.0f},{hy:.0f})"))
    sys.exit(0 if all(results) else 1)


if __name__ == "__main__":
    main()
