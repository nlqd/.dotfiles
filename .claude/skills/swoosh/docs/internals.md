# How swoosh works

## Recording

- `scripts/headless-sway` runs one command in a fresh headless sway at 2880x1620, scale 1.5: its own config and D-Bus session, the AMD GPU (`/dev/dri/renderD128`), and a transparent cursor theme so the capture has no cursor in it. The user's desktop, portals and pointer are never involved.
- `scripts/vpointer` is a small C daemon holding a wlr virtual pointer open. It gives the headless seat a real pointer, so pages see hovers and clicks. `wtype` types.
- wf-recorder captures a true 60 fps, encoded on the GPU, into `raw.mp4`. 4K60 drops frames on this machine and 30 fps makes scrolls judder; damage-driven capture hangs on stop at this size.
- `Session` writes `cursor.jsonl` alongside: every pointer position with its timestamp, plus focus, click, type, key and scroll events. The format is at the top of `scripts/demo_driver.py`.
- If a tour dies, the kernel kills its recorder. After any failure, still check `pgrep --list-full wf-recorder` and stop leftovers.

## Rendering

`scripts/render.py` turns `raw.mp4` and `cursor.jsonl` into the final video:

- Shots: nearby targets share a shot, a scroll always ends one, and consecutive shots hand over so the camera never jumps.
- Camera: eased zoom (1.8x, less when a shot's targets are spread out) and pans, never zoomed through a scroll, cut from the high-resolution capture so text stays sharp.
- Cursor: drawn at 60 fps from Adwaita's 96 px sprites, spring-smoothed, with motion blur and a press animation; a hand while inside a link's box.
- Overlays: click ripples, a keystroke pill at the bottom of the window, gradient backdrop with rounded corners and a shadow.
- Dead time at both ends is trimmed. The video is written to a side file and renamed only on success, so a failed render never replaces a good one.

## Test

`swoosh test` renders a synthetic take and checks the output format, that the camera lands on the target within a few pixels, that it never kinks at the frame edge or jumps between shots, that a brief hover is held before handing over, that both ends are trimmed, that a truncated take fails without clobbering an earlier render, and that the sheet shows the right moments. Run it after changing `render.py`.

## Known limits

- The keystroke pill can run one or two characters ahead of or behind the screen, because wtype's timing jitters.
- Video a page plays itself (a hero background, for example) stays at its own frame rate.
