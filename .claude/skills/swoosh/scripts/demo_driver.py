"""Drive a headless sway session and log cursor telemetry next to the recording.

Telemetry is JSONL, one event per line:
  {"t": seconds since recorder spawn, "x": px, "y": px, "kind": ...}
x/y are video pixels (logical * scale). Kinds: move, down, up, focus (hover dwell,
zoom-worthy), type, key, scroll (page scroll starts, zoom out). The last line is
{"kind": "stop", "t": ...}; the renderer aligns t to the video with
offset = stop.t - video_duration, since wf-recorder's startup latency is unknown.
"""

import contextlib
import ctypes
import json
import math
import os
import signal
import subprocess
import tempfile
import time
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent


def _die_with_parent():
    # A crashed take is useless, and a recorder left behind can hang forever while
    # finishing, so the kernel SIGKILLs it when the tour dies. Normal stops send
    # SIGINT so the mp4 gets finalized.
    PR_SET_PDEATHSIG = 1
    ctypes.CDLL("libc.so.6", use_errno=True).prctl(PR_SET_PDEATHSIG, signal.SIGKILL)


def devtools_preferences(text_filter="domain:localhost", types=("Doc", "Fetch"), height=380,
                         preserve_log=True):
    """Chrome profile Preferences that open DevTools readable: Network tab, docked at the
    bottom, height logical px tall, showing only the given resource types and text_filter.

    DevTools stores each preference as a JSON string inside the JSON file, hence the
    double encoding. Several keys exist under two spellings across Chrome versions.
    """
    # DevTools has keyed these filters by name, short title and lowercase across
    # versions; set every spelling so whichever this Chrome reads is on.
    spellings = {"Doc": ["Doc", "Document", "document"],
                 "Fetch": ["Fetch", "XHR", "xhr", "Fetch/XHR", "Fetch and XHR", "fetch"],
                 "JS": ["JS", "Script", "script"], "CSS": ["CSS", "Stylesheet", "stylesheet"],
                 "Img": ["Img", "Image", "image"], "Media": ["Media", "media"],
                 "Font": ["Font", "font"], "WS": ["WS", "Socket", "WebSocket", "websocket"]}
    type_filter = {name: True for t in types for name in spellings.get(t, [t])}
    split = json.dumps({"horizontal": {"size": height}})
    prefs = {
        "currentDockState": '"bottom"', "current-dock-state": '"bottom"',
        "panel-selectedTab": '"network"', "panel-selected-tab": '"network"',
        "network-log.preserve-log": json.dumps(preserve_log),
        "network-log.preserve-log-ui": json.dumps(preserve_log),
        "network.group-by-frame": "false",
        "network-text-filter": json.dumps(text_filter or ""),
        "network-resource-type-filters": json.dumps(type_filter),
        "inspector-view.split-view-state": split, "InspectorView_splitViewState": split,
    }
    return {"devtools": {"preferences": prefs}}


def ease_in_out(u):
    return 0.5 - 0.5 * math.cos(math.pi * u)


class Session:
    """One recorded take. Scale and fps come from `swoosh record`, which also sets up the display."""

    def __init__(self, out_dir, width=1920, height=1080, camera="zoom"):
        """camera="still" never zooms, for takes whose whole window matters (reviewer mode)."""
        if camera not in ("zoom", "still"):
            raise ValueError(f"camera must be 'zoom' or 'still', not {camera!r}")
        self.camera = camera
        try:
            self.scale = float(os.environ["SWOOSH_SCALE"])
            self.fps = int(os.environ["SWOOSH_FPS"])
        except KeyError as missing:
            raise RuntimeError(f"{missing} is not set; run tours through `swoosh record`") from None
        if not (SCRIPTS / "vpointer").exists():
            raise RuntimeError(f"{SCRIPTS / 'vpointer'} is missing; run `swoosh build` first")
        self.out = Path(out_dir)
        self.out.mkdir(parents=True, exist_ok=True)
        self.x, self.y = width / 2, height / 2
        self.log = open(self.out / "cursor.jsonl", "w")
        self.pointer = subprocess.Popen(
            [str(SCRIPTS / "vpointer"), str(width), str(height)],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1,
        )
        if self.pointer.stdout.readline().strip() != "ready":
            raise RuntimeError("vpointer did not start")
        self.recorder = None
        self.t0 = None

    def spawn(self, argv, settle=2.0):
        proc = subprocess.Popen(argv, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        time.sleep(settle)
        return proc

    @contextlib.contextmanager
    def chrome(self, *args, settle=2.0, devtools=None):
        """Chrome on the headless display with a throwaway profile, removed afterwards.

        args are extra flags and the URL, e.g. ("--kiosk", url) or ("--app=" + url,).
        devtools (a dict, {} for defaults) opens DevTools docked at the bottom on the
        Network tab, for reviewers who want to see requests; see devtools_preferences.
        It also holds the camera still: any zoom would crop the address bar or the panel.
        """
        with tempfile.TemporaryDirectory(prefix="swoosh-chrome-") as profile:
            if devtools is not None:
                self.camera = "still"
                default = Path(profile) / "Default"
                default.mkdir()
                (default / "Preferences").write_text(json.dumps(devtools_preferences(**devtools)))
                args = ("--auto-open-devtools-for-tabs", "--start-maximized", *args)
            proc = self.spawn(
                ["google-chrome", "--ozone-platform=wayland", f"--user-data-dir={profile}",
                 "--no-first-run", "--no-default-browser-check", "--disable-features=Translate",
                 "--hide-crash-restore-bubble",
                 # The private D-Bus session has no keyring; without this Chrome blocks
                 # its network service waiting for one and stays on about:blank.
                 "--password-store=basic", *args], settle)
            try:
                yield proc
            finally:
                proc.terminate()
                try:
                    proc.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait()

    def start_recording(self):
        # Constant frame rate with VAAPI encoding is what holds a true 60 fps here.
        # Damage-driven capture builds a backlog at this size and hangs on stop.
        self.recorder = subprocess.Popen(
            ["wf-recorder", "--output", "HEADLESS-1", "--no-damage",
             "--framerate", str(self.fps),
             "--codec", "h264_vaapi", "--device", "/dev/dri/renderD128", "-p", "qp=16",
             "--file", str(self.out / "raw.mp4"), "-y"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            preexec_fn=_die_with_parent,
        )
        self.t0 = time.monotonic()
        self._emit("move")
        if self.camera != "zoom":
            self._write({"t": 0.0, "kind": "camera", "mode": self.camera})

    def stop_recording(self):
        self._write({"t": self._t(), "kind": "stop"})
        self.recorder.send_signal(signal.SIGINT)
        try:
            self.recorder.wait(timeout=60)
        except subprocess.TimeoutExpired:
            self.recorder.kill()
            self.recorder.wait()
            raise RuntimeError("wf-recorder did not finish within 60 s of SIGINT; "
                               "killed it, raw.mp4 is likely unplayable")
        self.log.close()
        self.pointer.stdin.close()
        self.pointer.wait(timeout=5)

    def _t(self):
        return round(time.monotonic() - self.t0, 4)

    def _write(self, event):
        self.log.write(json.dumps(event) + "\n")
        self.log.flush()

    def _emit(self, kind, **extra):
        if self.t0 is not None:
            event = {"t": self._t(), "x": round(self.x * self.scale, 1),
                     "y": round(self.y * self.scale, 1), "kind": kind}
            event.update({k: v for k, v in extra.items() if v is not None})
            self._write(event)

    def _send(self, line):
        self.pointer.stdin.write(line + "\n")

    def move_to(self, x, y, duration=None):
        dist = math.hypot(x - self.x, y - self.y)
        duration = duration if duration is not None else min(1.2, 0.35 + dist / 1800)
        # Position comes from the real elapsed time, not the step count, so a late
        # wake-up never pairs a planned position with a later timestamp.
        # A hand rarely moves in a straight line: bow the path into a gentle arc
        # (quadratic Bezier, control point 12% of the distance off the chord).
        x0, y0 = self.x, self.y
        bow = 0.12 if x >= x0 else -0.12
        mx, my = (x0 + x) / 2 - (y - y0) * bow, (y0 + y) / 2 + (x - x0) * bow
        start = time.monotonic()
        while True:
            u = min(1.0, (time.monotonic() - start) / duration)
            e = ease_in_out(u)
            self.x = (1 - e) ** 2 * x0 + 2 * (1 - e) * e * mx + e ** 2 * x
            self.y = (1 - e) ** 2 * y0 + 2 * (1 - e) * e * my + e ** 2 * y
            self._send(f"move {self.x:.1f} {self.y:.1f}")
            self._emit("move")
            if u >= 1.0:
                break
            time.sleep(1 / 120)

    def click(self, x=None, y=None):
        if x is not None:
            self.move_to(x, y)
            time.sleep(0.15)
        self._send("down")
        self._emit("down")
        time.sleep(0.08)
        self._send("up")
        self._emit("up")
        time.sleep(0.25)

    def focus(self, x, y, dwell=1.2, cursor=None, box=None):
        """Hover a target worth looking at; the camera zooms on it like on a click.

        cursor is the CSS cursor over the target ("pointer" for links) and box its
        logical [x0, y0, x1, y1]; with both, the drawn cursor is a hand exactly while
        the pointer is over the element.
        """
        if cursor is not None and box is None:
            raise ValueError("focus(cursor=...) needs box= too; the hand shows only inside the box")
        self.move_to(x, y)
        if box is not None:
            box = [round(v * self.scale, 1) for v in box]
        self._emit("focus", cursor=cursor, box=box)
        time.sleep(dwell)

    def mark(self, kind):
        self._emit(kind)

    def type(self, text, delay_ms=55):
        # lead is wtype's -s sleep below; the renderer reveals char i at t + lead + i * delay.
        self._emit("type", text=text, delay=delay_ms / 1000, lead=0.2)
        # The first key races the client's keymap load; Chrome drops it without the sleep.
        subprocess.run(["wtype", "-s", "200", "-d", str(delay_ms), text], check=True)

    def key(self, name):
        self._emit("key", key=name)
        subprocess.run(["wtype", "-k", name], check=True)

    def pause(self, seconds):
        time.sleep(seconds)
