---
name: swoosh
description: Use when you need to record a short polished screen video as proof of work, for a pull request description or a reviewer, showing a web page, a browser app, a terminal, or any Wayland app doing something. Records a scripted demo on a throwaway headless sway (never the user's screen, no portal picker), then renders a Screen-Studio-style video with auto-zoom on hovered/clicked targets, a large smooth cursor, click ripples and a keystroke overlay. Not for watching or analyzing an existing video; that's video-frame-reader.
---

# swoosh

`swoosh` (on PATH) turns a scripted demo into a 1920x1080 60 fps video that zooms in on what the cursor is doing. It records on a private headless display, never the user's screen.

1. Write a tour, a short Python script driving the demo. Read `swoosh help tour` first; copy one of the examples it points to.
2. Record and render:
   ```
   swoosh record tour.py out/      # out/raw.mp4 + out/cursor.jsonl
   swoosh render out/              # out/demo.mp4
   swoosh sheet out/               # out/sheet.png
   ```
3. Look at `out/sheet.png` with Read before handing the video over: every target in frame, the right cursor shape, no cookie banner or dialog.
4. Ask the user before publishing the video anywhere. With their yes, `gh pr edit N --attach out/demo.mp4` puts it in the PR description as an inline player.

For code reviewers, `swoosh help tour` also covers reviewer mode: the address bar and a DevTools Network panel stay in the video and the camera holds still.

More, only when needed: `swoosh help internals` when something breaks, `swoosh help porting` for other platforms.
